import Foundation
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Quit with Chromium's pages and the Chromium Host (task 087 of plans/cmux-next/chrome-parity/p01-process.md).
extension CEFRuntime {
    /// How long a page's beforeunload handlers may take to say whether the page asks: a page that does not answer in
    /// time does not hold the quit, as Chrome's beforeunload timer proceeds without a hung renderer
    /// (`RenderFrameHostImpl::BeforeUnloadTimeout`, content/browser/renderer_host/render_frame_host_impl.cc).
    static let quitAskLimit: Duration = .seconds(1)

    /// Closes every browser and calls CefShutdown (``closeBrowsersAndShutDown(timeout:)``). Host mode: no host starts
    /// once quit began, and the host is gone before this returns, ``CEFShutdownSequence/hostEndLimit`` at most (then it
    /// is SIGKILLed): a host left running would hold the app bundle an update replaces and the data folder the next
    /// launch's host needs.
    func shutdown(timeout: Duration) async {
        if hostStart != nil, state == .idle { state = .shutDown }
        await closeBrowsersAndShutDown(timeout: timeout)
        await hostStart?.endHost(within: CEFShutdownSequence.hostEndLimit)
    }

    /// Before quit closes anything, every page whose beforeunload would ask ("Leave site?") asks the person, one page at
    /// a time, its tab brought forward; the first Stay ends the quit and every page stays as it was. Chrome's quit runs
    /// each tab's beforeunload first and closes nothing until every one proceeds (`BrowserCloseManager`,
    /// chrome/browser/lifetime/browser_close_manager.cc; `UnloadController`, chrome/browser/ui/unload_controller.cc).
    ///
    /// `asks` says whether a page would ask; the pages answer in parallel, each within ``quitAskLimit``. Only the
    /// question waits for the person. `showWindows` runs before the first question: the windows an update's install
    /// click hid come back. The quit's close afterwards never asks again (`cmux_shim_close_all` answers Leave).
    func askPagesBeforeQuit(showWindows: () -> Void,
                            asks: @escaping @MainActor @Sendable (CEFTab) async -> Bool) async -> ChromiumQuitAnswer {
        guard state == .ready, shutdownSequence == nil else { return .leave(asked: false) }
        let tabs = tabsByBrowser.sorted { $0.key < $1.key }.map(\.value).filter { !$0.isClosed }
        let answers = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, tab) in tabs.enumerated() {
                group.addTask { @MainActor in (index, await asks(tab)) }
            }
            var asking: Set<Int> = []
            for await (index, wouldAsk) in group where wouldAsk { asking.insert(index) }
            return asking
        }
        var asked = false
        for (index, tab) in tabs.enumerated() where answers.contains(index) && !tab.isClosed {
            if !asked { showWindows() }
            asked = true
            guard await tab.askBeforeQuit() else { return .stay }
        }
        return .leave(asked: asked)
    }

    /// Answers every page's waiting beforeunload question: Leave with `leave` (a signal's quit, which never waits on a
    /// question), else Stay.
    func answerQuitQuestions(leave: Bool) {
        for tab in hosts.values.flatMap(\.tabs) {
            for prompt in tab.pendingPrompts where prompt.kind.isBeforeUnload && !prompt.isResolved {
                prompt.respond(leave ? .accept : .cancel)
            }
        }
    }
}

extension CEFTab {
    /// Whether this page would ask before it unloads: its top document's beforeunload handlers run through the page
    /// recorder (`BrowserPageBusy.askScript`, as the hibernation's last check runs them), and only a document the person
    /// used asks (Chrome's sticky user activation rule for the beforeunload dialog). False when the page does not answer
    /// within `limit`. The fork has no beforeunload dispatch that keeps the page: CEF's TryCloseBrowser closes a page
    /// that does not ask, and a later Stay could not bring it back.
    func asksBeforeQuit(within limit: Duration) async -> Bool {
        guard let browserID, !isClosed else { return false }
        let script = BrowserPageBusy.askScript
        let value: BrowserJSValue?
        if runtime.forkFeatures.rendererPaths {
            value = try? await runtime.evaluate(browserID, world: "", script: script, userGesture: false, timeout: limit).value()
        } else {
            let json = try? await runtime.devTools(browserID, method: "Runtime.evaluate",
                                                   params: ["expression": script, "returnByValue": true, "awaitPromise": true],
                                                   timeout: limit)
            value = json.flatMap { try? CEFDevToolsResult.evaluation($0) }
        }
        guard case .bool(let asks)? = value else { return false }
        return asks
    }

    /// Shows the page's beforeunload question over it (``BrowserPromptKind/beforeUnload(isReload:)``), its tab brought
    /// forward as for a person's close; true for Leave. A tab that closes meanwhile leaves.
    func askBeforeQuit() async -> Bool {
        if host.visibleTab !== self { emit(.activate) }
        let origin = committedURL?.absoluteString ?? ""
        // A question dropped unanswered leaves, as a closed tab's does (`BrowserPrompt.dismissalResponse`).
        let response = try? await withOnceContinuation { (answer: OnceContinuation<BrowserPromptResponse, OnceContinuationError>) in
            enqueuePrompt(.beforeUnload(isReload: false), origin: origin) { _ = answer.resume(returning: $0) }
        }
        return (response ?? .accept) == .accept
    }
}
