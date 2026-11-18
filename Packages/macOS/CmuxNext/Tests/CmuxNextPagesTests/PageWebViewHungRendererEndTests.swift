import AppKit
import CmuxNextDesign
@testable import CmuxNextPages
import CmuxNextPagesTestSupport
import CmuxNextTestSupport
import Foundation
import Testing

/// Two agent chats in one Chromium renderer, one stuck in `for (;;) {}` (NIGHTLY 9d514c685e48:
/// one renderer at 100% CPU, past 14 GB, every chat in it frozen). The liveness watchdog ends that
/// renderer: both chats reload as a repair (never the crash notice), each says once that it was
/// restarted, and the log names both, since they share one main thread and the host cannot tell
/// which one loops.
@MainActor @Suite(.closesItsWindows)
struct PageWebViewHungRendererEndTests {
    private let root: URL
    private let descriptor = PageDescriptor(id: "test.hung-renderer", resource: "hung-renderer", namespaces: [])

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("page-hung-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Chat</title>".utf8).write(to: root.appendingPathComponent("index.html"))
    }

    /// A renderer with a client id no other test's renderer has: an end marks every open page of
    /// its renderer, so a shared id would reach another test's pages.
    private func newRenderer() -> FakeRendererProcess {
        FakeRendererProcess(clientID: Int32.random(in: 1_000_000...Int32.max))
    }

    /// A chat page in Chromium under a host that shows the crash notice (the agent pane's rule).
    private func chat(_ hosting: FakeChromiumHosting, session: String, renderer: FakeRendererProcess) async throws -> (PageWebView, FakeChromiumPage) {
        let view = try #require(PageWebView(descriptor: descriptor, root: root, routes: [], chromium: hosting))
        view.chromiumClock = PageTestClock.never
        await view.chromiumStart?.value
        let page = try #require(hosting.made.last)
        page.rendererProcess = renderer
        view.reloadsAfterCrash = false
        view.logIdentity = { "session=\(session) tab=tab-\(session)" }
        return (view, page)
    }

    /// One window's toasts, as the agent panes of that window share them (``CmuxToastCenter``).
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func bothChatsOfTheEndedRendererReloadAndEachSaysItRestarted() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        let (looping, loopingPage) = try await chat(hosting, session: "s-loop", renderer: renderer)
        let (idle, idlePage) = try await chat(hosting, session: "s-idle", renderer: renderer)
        // Both panes in one window, so their notices go to one toast stack.
        let toasts = CmuxToastCenter()
        let window = window()
        defer { window.close() }
        var notices: [CmuxToast] = []
        var crashNotices = 0
        for view in [looping, idle] {
            view.onRendererRestarted = { toast in
                notices.append(toast)
                toasts.show(toast, in: window)
            }
            view.onCrash = { _, _ in crashNotices += 1 }
        }

        // The log line names both chats of the renderer.
        let entries = [looping, idle].map { $0.livenessLogEntry(visible: true, now: 100) }
        #expect(entries[0].contains("session=s-loop tab=tab-s-loop") && entries[0].contains("visible"))
        #expect(entries[1].contains("session=s-idle tab=tab-s-idle"))

        // One end, for the one renderer they share.
        #expect(PageWebView.endHungRenderer(of: [looping, idle], notice: "restarted") == 4242)
        #expect(renderer.ends == 1)

        // Chromium reports the renderer gone to both tabs: each reloads in a new renderer, no notice.
        loopingPage.onEvent?(.crashed)
        idlePage.onEvent?(.crashed)
        // Each reload waits for the restart line's script to be taken (answered here at once).
        for view in [looping, idle] { await view.restartFlagReload?.value }
        #expect(loopingPage.reloads == 1 && idlePage.reloads == 1, "a chat of the ended renderer did not reload")
        #expect(crashNotices == 0, "an ended renderer showed the crash notice instead of reloading")
        #expect(looping.showsChromium && idle.showsChromium, "a chat fell back to WebKit")

        // Each new document loads: its pane says once that it restarted, never silently.
        looping.documentFinished()
        idle.documentFinished()
        #expect(notices.map(\.message) == ["restarted", "restarted"])
        // Both notices show at once in the window they share: neither replaced the other.
        #expect(toasts.toasts(in: window).map(\.id) == notices.map(\.id), "one chat's restart notice replaced the other's")
        #expect(Set(notices.map(\.kind)).count == 1, "the notices are not one kind for Don't Show Again")
        looping.documentFinished()
        #expect(notices.count == 2, "a later load repeated the notice")

        // A later crash is a crash again: the notice is the person's.
        loopingPage.onEvent?(.crashed)
        #expect(crashNotices == 1 && loopingPage.reloads == 1)
        looping.close()
        idle.close()
    }

    /// A chat still booting has sent no beat, so no watchdog part times it (App Health's feed joins
    /// a page on its first beat), yet it lives in the renderer that ends: it reloads with the notice
    /// like the rest, never the crash notice. A chat in another renderer is left alone.
    @Test func aChatStillBootingInTheEndedRendererReloadsWithTheNotice() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        let (looping, loopingPage) = try await chat(hosting, session: "s-loop", renderer: renderer)
        let (booting, bootingPage) = try await chat(hosting, session: "s-boot", renderer: renderer)
        let (other, otherPage) = try await chat(hosting, session: "s-other", renderer: newRenderer())
        var notices: [String: [String]] = [:]
        var crashNotices: [String: Int] = [:]
        for (name, view) in [("loop", looping), ("boot", booting), ("other", other)] {
            view.onRendererRestarted = { notices[name, default: []].append($0.message) }
            view.onCrash = { _, _ in crashNotices[name, default: 0] += 1 }
        }

        // The feed passes only the pages its part has (the booting one has not joined).
        #expect(PageWebView.endHungRenderer(of: [looping], notice: "restarted") == 4242)
        loopingPage.onEvent?(.crashed)
        bootingPage.onEvent?(.crashed)
        for view in [looping, booting] { await view.restartFlagReload?.value }
        #expect(bootingPage.reloads == 1, "a booting chat of the ended renderer did not reload")
        #expect(crashNotices["boot"] == nil, "a booting chat of the ended renderer showed the crash notice")
        booting.documentFinished()
        looping.documentFinished()
        #expect(notices["boot"] == ["restarted"] && notices["loop"] == ["restarted"])

        // The other renderer's chat was not marked: its own end is a crash, with no restart line.
        otherPage.onEvent?(.crashed)
        other.documentFinished()
        #expect(crashNotices["other"] == 1 && otherPage.reloads == 0 && notices["other"] == nil)
        for view in [looping, booting, other] { view.close() }
    }

    /// The architect's condition (5) with 4 or more chats of one renderer in a window: a window's
    /// toasts fade the oldest, so the line goes into each chat too. Every page of the ended
    /// renderer, the ones the feed passed and one still booting, gets the restart line as a script
    /// for its next document, once; it comes off after that document loaded, and a chat of another
    /// renderer gets none.
    @Test func eachChatOfTheEndedRendererGetsTheRestartLineForItsNextDocument() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        var chats: [(PageWebView, FakeChromiumPage)] = []
        for index in 0..<5 { chats.append(try await chat(hosting, session: "s-\(index)", renderer: renderer)) }
        let (other, otherPage) = try await chat(hosting, session: "s-other", renderer: newRenderer())
        let line = "This chat stopped responding, so cmux restarted it."
        let addScript = "Page.addScriptToEvaluateOnNewDocument"
        // Only the setup's scripts so far.
        let setupAdds = chats.map { $0.1.calls.filter { $0.method == addScript }.count }

        // The feed passes four; the fifth is still booting in the same renderer.
        #expect(PageWebView.endHungRenderer(of: chats.prefix(4).map(\.0), notice: line) != nil)
        for (_, page) in chats { page.onEvent?(.crashed) }
        for (view, _) in chats { await view.restartFlagReload?.value }

        for ((view, page), before) in zip(chats, setupAdds) {
            let adds = page.calls.filter { $0.method == addScript }
            #expect(adds.count == before + 1, "a chat of the ended renderer got no restart line for its next document")
            let source = adds.last?.params["source"] as? String ?? ""
            #expect(source.contains(PageWebView.restartFlagGlobal) && source.contains(ChromiumPageHostWire.jsonString(line)))
            #expect(adds.last?.params["runImmediately"] as? Bool == true)
            #expect(page.reloads == 1)
            view.documentFinished()
        }
        // Each restarted document loaded: its script comes off, so a later reload has no line.
        for (view, page) in chats {
            await view.restartFlagRemoval?.value
            #expect(page.calls.last { $0.method == "Page.removeScriptToEvaluateOnNewDocument" }?.params["identifier"] as? String == "test-script")
            view.documentFinished()
            #expect(page.calls.filter { $0.method == "Page.removeScriptToEvaluateOnNewDocument" }.count == 1)
        }
        // The other renderer's chat crashes as a crash: no line.
        let otherAdds = otherPage.calls.filter { $0.method == addScript }.count
        otherPage.onEvent?(.crashed)
        #expect(other.restartFlagScript == nil && otherPage.calls.filter { $0.method == addScript }.count == otherAdds)
        for (view, _) in chats { view.close() }
        other.close()
    }

    /// Architect review of #46474 (F1): the reload ran at once while the restart line's script was
    /// still being registered, so a fast navigation could reach its first document without the
    /// line. The reload now waits for Chromium's answer to that registration.
    @Test func theReloadWaitsForTheRestartLineScriptToBeTaken() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await chat(hosting, session: "s-wait", renderer: newRenderer())
        let addScript = "Page.addScriptToEvaluateOnNewDocument"
        page.held = [addScript]

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") != nil)
        page.onEvent?(.crashed)
        for _ in 0..<20 { await Task.yield() }
        #expect(page.calls.last { $0.method == addScript }?.params["source"] as? String != nil, "the restart line's script was not asked for")
        #expect(page.reloads == 0, "the page reloaded before Chromium took the restart line's script")

        page.release(addScript)
        await view.restartFlagReload?.value
        #expect(page.reloads == 1, "the page did not reload once the script was taken")
        #expect(view.restartFlagNote == nil)
        view.close()
    }

    /// F1's bound: when the registration is never answered in time, the page reloads anyway (a chat
    /// that stays down is worse than one without its line) and the log says why.
    @Test func anUnansweredRegistrationStillReloadsAndLogsWhy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await chat(hosting, session: "s-late", renderer: newRenderer())
        let addScript = "Page.addScriptToEvaluateOnNewDocument"
        page.held = [addScript]
        // The wait runs out at once.
        view.chromiumClock = PageTestClock.immediate

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") != nil)
        page.onEvent?(.crashed)
        await view.restartFlagReload?.value
        #expect(page.reloads == 1, "an unanswered registration kept the chat from reloading")
        #expect(view.restartFlagNote?.contains("not answered within") == true, "the reload without the script logged no reason")

        // The late answer still lets the script come off once the document loaded.
        page.release(addScript)
        _ = await view.restartFlagScript?.value
        view.close()
    }

    /// A registration Chromium refused: the page reloads at once and the log says the chat shows only the toast.
    @Test func aFailedRegistrationReloadsAndLogsWhy() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let (view, page) = try await chat(hosting, session: "s-fail", renderer: newRenderer())
        page.answer = { method, _ in method == "Page.addScriptToEvaluateOnNewDocument" ? "{}" : nil }

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") != nil)
        page.onEvent?(.crashed)
        await view.restartFlagReload?.value
        #expect(page.reloads == 1)
        #expect(view.restartFlagNote?.contains("failed to register") == true)
        view.close()
    }

    /// Don't Show Again on the restart toast was saved under the agent pane's old toast id
    /// (`agentPane.rendererRestarted`, its kind by default): that saved choice still hides every
    /// page's restart toast now that each page has its own id.
    @Test func aRestartToastHiddenBeforeStaysHidden() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "page-hung-toast-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["agentPane.rendererRestarted"], forKey: CmuxToastNeverShowStore.defaultsKey)
        let toasts = CmuxToastCenter(neverShow: CmuxToastNeverShowStore(defaults: defaults))
        let window = window()
        defer { window.close() }
        let hosting = FakeChromiumHosting()
        let (view, _) = try await chat(hosting, session: "s-hidden", renderer: newRenderer())
        let toast = view.rendererRestartedToast("restarted")
        #expect(toast.kind == "agentPane.rendererRestarted" && toast.offersNeverShow)
        toasts.show(toast, in: window)
        #expect(toasts.toasts(in: window).isEmpty, "a restart toast the person hid before showed again")
        view.close()
    }

    @Test func anEndThatEndedNothingTakesTheMarksBack() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let hosting = FakeChromiumHosting()
        let renderer = newRenderer()
        renderer.endAnswer = nil
        let (view, page) = try await chat(hosting, session: "s-1", renderer: renderer)
        let (booting, bootingPage) = try await chat(hosting, session: "s-2", renderer: renderer)
        var notices: [String] = []
        var crashNotices = 0
        for chat in [view, booting] {
            chat.onRendererRestarted = { notices.append($0.message) }
            chat.onCrash = { _, _ in crashNotices += 1 }
        }

        #expect(PageWebView.endHungRenderer(of: [view], notice: "restarted") == nil)
        // The renderer later dies on its own: that is a crash, with its notice and no reload, for
        // the page passed and the one it would have marked.
        page.onEvent?(.crashed)
        bootingPage.onEvent?(.crashed)
        #expect(crashNotices == 2 && page.reloads == 0 && bootingPage.reloads == 0)
        view.documentFinished()
        booting.documentFinished()
        #expect(notices.isEmpty, "a renderer the watchdog did not end said it was restarted")
        view.close()
        booting.close()
    }
}
