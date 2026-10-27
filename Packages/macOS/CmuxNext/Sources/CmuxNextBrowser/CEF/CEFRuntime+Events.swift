import AppKit
import CmuxNextCompat
import CmuxNextInput
import Foundation
import os
import CmuxNextWakeups
import CmuxSafeConcurrency

/// Faults from shim callbacks that arrive off the CEF UI (main) thread.
private let callbackLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

/// C entry for shim events (main thread).
let cefEventCallback: CEFShimLibrary.EventFn = { context, kind, browser, request, a, b, s1, s2 in
    // SAFETY: only the context's address is read; CEFRuntime.from turns it back into the runtime.
    let address = unsafe UInt(bitPattern: context)
    guard address != 0 else { return }
    // SAFETY: the shim's strings are NUL-terminated and valid during this call; String(cString:) copies each.
    let text = unsafe (s1.map(String.init(cString:)) ?? "", s2.map(String.init(cString:)) ?? "")
    let event = CEFShimEvent(kind: kind, browser: browser, request: request, a: a, b: b, s1: text.0, s2: text.1)
    // The shim emits on the CEF UI thread, which is the main thread. If a
    // future shim path emits elsewhere, hop instead of trapping in
    // assumeIsolated (the strings are already copied into `event`).
    guard Thread.isMainThread else {
        // FIFO with every other run-loop block: a commit or a crash is never reordered by class.
        return MainRunLoopBlock.perform { CEFRuntime.from(address)?.receive(event) }
    }
    MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        CEFRuntime.from(address)?.receive(event)
    }
}

/// C entry before the page sees a key down: app shortcuts win. In process only: the Chromium Host passes a NULL key_fn (browser_host_main.mm, `cmux_shim_initialize`).
let cefKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    // Keys arrive on the main thread; off it, let the page have the key
    // rather than trap in assumeIsolated.
    // SAFETY: only the addresses are read; CEFRuntime.from and CEFKeyEventAddress turn them back.
    let (address, eventAddress) = unsafe (UInt(bitPattern: context), CEFKeyEventAddress(nsEvent))
    guard address != 0, eventAddress.isSome, Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        guard let runtime = CEFRuntime.from(address), let event = eventAddress.event() else { return 0 }
        return runtime.routeKey(event, browser: browser) ? 1 : 0
    }
}

/// C entry after the page left a key down unhandled: the host's held shortcut runs.
let cefUnhandledKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    // Keys arrive on the main thread; off it, Chromium keeps the key.
    // SAFETY: as for cefKeyCallback.
    let (address, eventAddress) = unsafe (UInt(bitPattern: context), CEFKeyEventAddress(nsEvent))
    guard address != 0, eventAddress.isSome, Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        guard let runtime = CEFRuntime.from(address), let event = eventAddress.event() else { return 0 }
        return runtime.routeUnhandledKey(event, browser: browser) ? 1 : 0
    }
}

/// C entry before a DevTools browser sees a key down; `browser` is the
/// inspected page. In process only (``CEFDevToolsKeyPolicy/preKeyHook``).
let cefDevToolsKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    // SAFETY: as for cefKeyCallback.
    let (address, eventAddress) = unsafe (UInt(bitPattern: context), CEFKeyEventAddress(nsEvent))
    guard address != 0, eventAddress.isSome else { return 0 }
    // Keys arrive on the main thread; off it, the DevTools page keeps the key.
    guard Thread.isMainThread else {
        callbackLogger.fault("DevTools key callback off the main thread; the key goes to the page")
        return 0
    }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        guard let runtime = CEFRuntime.from(address), let event = eventAddress.event() else { return 0 }
        return runtime.routeDevToolsKey(event, inspected: browser) ? 1 : 0
    }
}

extension CEFRuntime {
    func dispatch(_ event: CEFShimEvent) {
        if mergedEvents.holds(event, for: event.browserID.flatMap { tabsByBrowser[$0] }) { return }
        switch event {
        case .contextInitialized:
            logger.info("CEF context initialized")
        case .afterCreated(let browser, let request, let window, let created):
            browserCreated(browser, request: request, window: window, created: created)
        case .popup, .unknown: break // AFTER_CREATED of a popup's tab carries its URL, disposition and gesture (pending popups)
        case .createFailed(let browser, let request): CEFCreateFailure(browser: browser, request: request).apply(to: self)
        case .chromeCommand(let browser, let command):
            chromeWindowCommandBlocked(command, browser: browser)
        case .beforeClose(let browser):
            widgetHost?.ownerClosed(browser)
            hostStart?.popupMenus?.ownerClosed(browser)
            hostStart?.files?.browserClosed(browser)
            browserClosed(browser)
        case .beforeUnloadDialog(let browser, let token, let isReload):
            // A page with no tab to ask in never keeps its unload waiting: it leaves.
            if let tab = tabsByBrowser[browser] { tab.beforeUnloadAsked(token: token, isReload: isReload) } else { _ = shim?.beforeUnloadReply(token, 1) }
        case .pageResource(let browser, let token, let url):
            answerPageResource(token: token, url: url, tab: tabsByBrowser[browser])
        case .pageMessage(let browser, let mainFrame, let channel, let payload):
            // Untrusted: a compromised renderer can post anything (`CEFPageMessage`).
            if let tab = tabsByBrowser[browser], let message = CEFPageMessage(channel: channel, payload: payload, mainFrame: mainFrame) {
                tab.agentRelay.pageMessage(message)
            }
        case .evaluateResult(let token, let status, let value):
            evaluationAnswered(token: token, CEFEvaluationResult(status: status, text: value))
        case .widgetContext(let context):
            widgetHost?.show(context)
        case .widgetGone(_, let widget):
            widgetHost?.remove(widget)
        case .pageView(let browser, let change):
            tabsByBrowser[browser]?.host.pageViewChanged(change, browser: browser)
        case .popupMenu(let browser, let token, let popup):
            popupMenuOpened(browser: browser, token: token, popup: popup)
        case .popupMenuHidden(let browser, let token):
            hostStart?.popupMenus?.hide(browser: browser, token: token)
        case .pageDragEnter(let browser, let pathsJSON):
            if let tab = tabsByBrowser[browser], let entered = tab.pageFilesDragged { entered(CEFTab.dragPaths(pathsJSON)) }
        case .fileDialog(let browser, let dialogID, let mode, let acceptTypes, let defaultPath):
            fileDialogAsked(dialogID, browser: browser, request: ChromiumFileDialogRequest(mode: mode, acceptTypes: acceptTypes, defaultPath: defaultPath))
        case .devToolsResult(let browser, let messageID, let success, let json):
            let key = CEFDevToolsKey(browser: browser, message: messageID)
            let result: Result<String, any Error> = success ? .success(json) : .failure(BrowserTabError.javaScript(json))
            if !devToolsCalls.resolve(key, with: result) {
                // A synchronous answer: devTools(_:method:) takes it when the shim call returns.
                synchronousDevToolsResults?[key] = result
            }
        case .reply(_, let id, let value, let json):
            let reply = CEFSiteReply(value: value, json: json)
            if !surfaceCopies.answer(reply: id, value: value, json: json), !builtInLoader.answer(reply: id, value: value),
               !siteReplies.resolve(id, with: .success(reply)), siteReplyBrowsers[id] != nil {
                earlySiteReplies[id] = reply
            }
        case .tab(let kind, let browser, let window, let value):
            forkTabEvent(kind, browser: browser, window: window, value: value)
        case .contextMenu(let browser, let token, let x, let y, let items, let params):
            showContextMenu(browser: browser, token: token, x: x, y: y, itemsJSON: items, paramsJSON: params)
        case .devToolsWillOpen(let browser):
            tabsByBrowser[browser]?.devToolsController.willOpen()
        case .devToolsOpened(let browser, let devTools, let docked):
            tabsByBrowser[browser]?.devToolsController.opened(browser: devTools, docked: docked)
        case .devToolsClosed(let browser, let devTools):
            tabsByBrowser[browser]?.devToolsController.closed(browser: devTools)
            hostStart?.popupMenus?.ownerClosed(devTools)
        case .installPrompt(let browser, let promptID, let json):
            extensionPrompts.arrived(promptID: promptID, browser: browser, json: json)
        case .download(let event):
            downloads.handle(event)
        case .omniboxSuggestions(let requestID, let extensionID, let json):
            omniboxKeywords.suggestionsArrived(requestID: requestID, extensionID: extensionID, json: json)
        case .authCallback(let browser, let url):
            signInCallbacks.stopped(browser: browser, url: url)
        case .keyUnhandledChord(let browser, let seq): redispatchUnhandledKey(seq: seq, browser: browser)
        case .bookmarks(let json, let path):
            CEFBookmarkBridge.shared.arrived(json: json, cachePath: path)
        case .renderTerminated(_, let status, let code, _, let end):
            rendererEnded(.cef(status: status, code: code), end: end) // counted whether or not a tab shows it
            fallthrough
        default:
            if let browser = event.browserID, let tab = tabsByBrowser[browser] {
                #if DEBUG || CMUX_BENCH_HOOKS
                CEFEventTrace.record(browser, event)
                #endif
                tab.handle(event)
            }
        }
    }

    /// Chromium's pre-key hook. A key without Command, Control or Option is the page's. A key the
    /// host's dispatcher decided in `sendEvent` never runs the dispatcher again: it goes to the page,
    /// after the profile's extension shortcuts when the dispatcher did not look them up. A key that
    /// never passed `sendEvent` runs the host's dispatcher (which also runs extension shortcuts),
    /// then, for Option chords the dispatcher does not see, the profile's extension shortcuts. Chrome
    /// decides a browser shortcut once and runs extension commands before the renderer
    /// (`BrowserView::PreHandleKeyboardEvent`, chrome/browser/ui/views/frame/browser_view.cc;
    /// `ExtensionKeybindingRegistry`, chrome/browser/extensions/extension_keybinding_registry.cc).
    func routeKey(_ event: NSEvent, browser: Int32) -> Bool { // perf-hot: 0.5ms key-dispatch (every key-down a Chromium page gets)
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let tab = tabsByBrowser[browser] else { return false }
        let router = tab.keyRouter
        switch router?.decidedKey(event) ?? .undecided {
        case .settled:
            return false
        case .extensionShortcutOwed:
            break
        case .undecided:
            if !event.modifierFlags.isDisjoint(with: [.command, .control]), let router,
               router.browserTab(tab, keyEquivalent: event) == .handledByHost {
                return true
            }
        }
        guard router?.pageOwnsAllKeys(tab) != true else { return false }
        return runProfileExtensionShortcut(event, in: tab)
    }

    /// The profile's extension shortcuts (`chrome.commands`), which Chromium would dispatch from
    /// the Chromium toolbar cmux hides.
    private func runProfileExtensionShortcut(_ event: NSEvent, in tab: CEFTab) -> Bool {
        let store = extensionStores.readyStore(for: tab.profileID)
        guard let command = store.command(matching: event) else { return false }
        return store.run(command, in: tab)
    }

    /// The page left a Command or Control chord unhandled: the host runs the shortcut it held
    /// back for the page (Find after a page without its own search), else Chromium goes on.
    func routeUnhandledKey(_ event: NSEvent, browser: Int32) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]),
              let tab = tabsByBrowser[browser], let router = tab.keyRouter else { return false }
        return router.browserTab(tab, unhandledKeyEquivalent: event)
    }

    func routeDevToolsKey(_ event: NSEvent, inspected browser: Int32) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]),
              let tab = tabsByBrowser[browser], let router = tab.keyRouter else { return false }
        return router.browserTab(tab, devToolsKeyEquivalent: event) == .handledByHost
    }

    // MARK: Browser lifetime

    private func browserCreated(_ browser: Int32, request: Int32, window: Int32, created: CEFCreatedBy) {
        // Host mode's `cef.create_browser` ends at the host's created reply, whoever takes the browser below.
        if request != 0 { spareWindow.createTrace.created(request: request) }
        if shutdownSequence != nil {
            // Its creation was under way when quit closed every browser (`shutdown`): close it
            // too, or the wait for Chromium's windows runs out and CefShutdown is skipped.
            pendingWindows[request] = nil
            shim?.close(browser)
            return
        }
        if request != 0, let host = pendingWindows.removeValue(forKey: request) {
            host.windowCreated(browser: browser, request: request)
            return
        }
        if let tab = tabBeingAdded {
            // cmux_tab_add runs OnAfterCreated before it returns.
            tabBeingAdded = nil
            register(tab, browser: browser)
            return
        }
        // Chromium created the tab itself (target=_blank, chrome.tabs.create).
        orphans.adopt(browser: browser, window: window, created: created)
    }

    func register(_ tab: CEFTab, browser: Int32) {
        windowRequests.linkClicks.onGesture = { [weak self] browser in
            guard let tab = self?.tabsByBrowser[browser] else { return }
            tab.automaticDownloads.userGesture()
            tab.pageUserInput?(ProcessInfo.processInfo.systemUptime)
        }
        startInput()
        tabsByBrowser[browser] = tab
        tab.attach(browser: browser)
        accessibility.attached(browser)
        signInCallbacks.attached(tab)
    }

    /// Gives the runtime `tap`, the input tap of the engine made now. It replaces the one before:
    /// link clicks and swipes that already hear a tap move to this one, so the newest engine's tap is
    /// always the one heard.
    func attachInput(_ tap: InputEventTap) {
        guard tap !== input else { return }
        input = tap
        if windowRequests.linkClicks.isRecording || swipeNavigation.isStarted { startInput() }
    }

    /// Link clicks and swipes hear `input` (a call with the tap they already hear does nothing).
    private func startInput() {
        guard let input else {
            if !reportedMissingInput {
                reportedMissingInput = true
                logger.fault("a Chromium tab registered with no input tap: link clicks and swipes are not heard")
            }
            return
        }
        windowRequests.linkClicks.startRecordingClicks(input: input) { [weak self] in self?.windowRequests.clickTargets() ?? [] }
        swipeNavigation.start(input: input)
    }

    private func browserClosed(_ browser: Int32) {
        windowRequests.linkClicks.forget(opener: browser)
        if let tab = tabsByBrowser.removeValue(forKey: browser) {
            mergedEvents.forget(tab, browser: browser)
            pageWindowWidgetsBrowserClosed(browser)
            tab.browserDidClose(closesTab: shutdownSequence == nil)
        } else {
            // Never registered: drop a pending adoption of it.
            orphans.closedUnregistered(browser)
        }
        devToolsCalls.failAll(where: { $0.browser == browser }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { siteReplyBrowsers[$0] == browser }, with: BrowserTabError.closed)
        failEvaluations(of: browser)
        surfaceCopies.browserClosed(browser)
        // The fork counts a browser's window until its destructor, after this close.
        if let shim { shutdownSequence?.windowsOpen(Int(shim.windowCount())) }
        shutdownSequence?.browserClosed(remaining: tabsByBrowser.count + pendingWindows.count)
        shutdownProgressed()
        pump?.scheduleNow()
    }

    private func forkTabEvent(_ kind: CEFForkTabEvent, browser: Int32, window: Int32, value: Int) {
        switch kind {
        case .extensionActionsChanged, .inserted, .removed:
            if kind == .inserted { orphans.placeUnplaced(browser: browser, window: window) }
            for host in hosts.values where host.owns(window: window) {
                host.refreshExtensionActions()
            }
            if kind == .extensionActionsChanged { extensionStores.refresh(window: window, browser: browser) }
        case .extensionsChanged:
            extensionStores.refresh(window: window, browser: browser)
        case .extensionPopupClosed:
            // `browser` is the window's active tab; the popup may have
            // opened from another tab of the same window.
            for tab in tabsByBrowser.values where tab.openExtensionPopup != nil || tab.browserID == browser {
                if tab.browserID == browser || tab.host.owns(window: window) { tab.extensionPopupClosed() }
            }
        case .windowDestroyed:
            shutdownSequence?.windowDestroyed(remaining: value)
            shutdownProgressed()
        case .activated:
            // Chromium (an extension) switched the window's tab: cmux selects it at the end of the turn, outside
            // Chromium's tab strip notification, which forbids re-entrant tab strip changes (cmux_tab_activate).
            // An echo of our own activation or of the tab's creation, late after the person chose another tab,
            // selects nothing: that stale completion jumped the selection back.
            if let tab = tabsByBrowser[browser], tab.host.visibleTab !== tab {
                guard tab.host.isForeignActivation(of: tab) else {
                    tab.host.lifecycleTrace.record(tab.id, "chromium-activated echo dropped")
                    return
                }
                tab.host.endOfTurn { [weak tab] in
                    guard let tab, tab.host.isForeignActivation(of: tab) else { return }
                    tab.host.lifecycleTrace.record(tab.id, "chromium-activated selects tab")
                    tab.emit(.activate)
                }
            }
        case .devToolsDockSide:
            tabsByBrowser[browser]?.devToolsController.dockSideChosen(value)
        case .devToolsDeviceMode:
            tabsByBrowser[browser]?.devToolsController.deviceModeChanged(on: value != 0)
        case .foreignBrowserBlocked:
            logger.error("Chromium created a window outside cmux (type \(value)); the fork hid it")
        case .popupWindowCreated:
            popupWindowCreated(window: window, browser: browser)
        case .popupWindowBounds:
            popupWindowBoundsChanged(window: window)
        case .sidePanelChanged:
            for host in hosts.values where host.owns(window: window) { host.visibleTab?.sidePanel.scheduleRefresh() }
        case .pageWindowWidget:
            pageWindowWidgetReported(CEFPageWindowWidgetEvent(value: value), window: window, browser: browser)
        case .moved, .unknown:
            break
        }
    }

    // MARK: DevTools

    /// Longest wait for an in-process DevTools result.
    static let devToolsTimeout: Duration = .seconds(5)

    /// Runs a DevTools method in process and returns its JSON result, or
    /// throws `timedOut` when no result arrives within `timeout`.
    func devTools(_ browser: Int32, method: String, params: [String: Any] = [:],
                  timeout: Duration = CEFRuntime.devToolsTimeout) async throws -> String {
        guard let shim else { throw BrowserTabError.closed }
        // Chromium answers some methods inside ExecuteDevToolsMethod, before a
        // waiter exists; without this the result was dropped and the call
        // timed out after `timeout` (every device emulation lost 5 s on
        // Emulation.setEmitTouchEventsForMouse).
        // A nested run loop inside the call may start another call: keep the outer one's table.
        let outer = synchronousDevToolsResults
        synchronousDevToolsResults = [:]
        let message = shim.devToolsCall(browser, method, CEFDevToolsResult.params(params))
        let answered = synchronousDevToolsResults
        synchronousDevToolsResults = outer.map { $0.merging(answered ?? [:]) { first, _ in first } }
        guard message != 0 else { throw BrowserTabError.closed }
        let key = CEFDevToolsKey(browser: browser, message: message)
        if let result = answered?[key] { return try result.get() }
        return try await devToolsCalls.reply(for: key, timeout: timeout) {
            BrowserTabError.timedOut("DevTools \(method) (\(timeout))")
        }
    }

    // MARK: Quit

    /// False once quit began to stop Chromium: CEF aborts making a browser after its shutdown
    /// began. AppKit still closes the windows after CefShutdown, and a hidden tab's view unhid
    /// there created one (crash on quit, NIGHTLY 1.0.0-nightly.3953614980201).
    var acceptsNewBrowsers: Bool { Self.acceptsNewBrowsers(state: state, stopping: shutdownSequence != nil) }

    static func acceptsNewBrowsers(state: State, stopping: Bool) -> Bool {
        state != .shutDown && !stopping
    }

    /// Closes every browser, waits (without blocking the main thread) until
    /// the Chromium windows are destroyed or `timeout` passes, then calls
    /// CefShutdown. The App awaits this from `applicationShouldTerminate`
    /// (terminate-later), so the run loop keeps pumping CEF meanwhile.
    func shutdown(timeout: Duration) async {
        if state == .loading {
            // The library is still mapping: never initialize after quit began.
            state = .shutDown
            return
        }
        // A second quit while the first waits would replace its waiter.
        guard state == .ready, shutdownSequence == nil, let shim else { return }
        // A pane's browser still being made (`pendingWindows`) counts as live: Chromium makes it after
        // `closeAll`, and `browserCreated` closes it.
        var sequence = CEFShutdownSequence(liveBrowsers: tabsByBrowser.count + pendingWindows.count, windows: Int(shim.windowCount()))
        sequence.begin()
        shutdownSequence = sequence
        noteCrashKeyShuttingDown()
        shim.closeAll()
        pump?.pumpNow()
        shutdownProgressed()
        if shutdownSequence?.phase != .readyToShutdown {
            // A waiter dropped unresumed (abandoned) ends the wait as the timeout does.
            try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                shutdownWaiter = continuation
                shutdownTimeout = waitDeadlines.schedule(owner: "CEFRuntime.shutdown", after: timeout) { [weak self] in
                    self?.resumeShutdownWaiter()
                }
            }
        }
        if let shutdownTimeout { _ = waitDeadlines.cancel(shutdownTimeout) }
        shutdownTimeout = nil
        // A create the host never answered before the wait ran out gets no reply now.
        spareWindow.createTrace.endUnanswered()
        devToolsCalls.failAll(where: { _ in true }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { _ in true }, with: BrowserTabError.closed)
        pump?.stop()
        guard shutdownSequence?.phase == .readyToShutdown else {
            logger.error("CEF shutdown timed out; exiting without CefShutdown")
            state = .shutDown
            return
        }
        shim.shutdown()
        state = .shutDown
        logger.notice("CEF shutdown complete")
    }

    /// Called after every close/destroy event during shutdown. A pane's browser still being made
    /// (`pendingWindows`) holds it too, while its Chromium window may not exist yet: its browser is
    /// closed when Chromium makes it (`browserCreated`), and `shutdown`'s timeout bounds the wait.
    /// Without it, no open window let quit call CefShutdown under the creation.
    func shutdownProgressed() {
        guard shutdownSequence != nil else { return }
        if let shim, shim.windowCount() == 0, tabsByBrowser.isEmpty, pendingWindows.isEmpty {
            shutdownSequence?.windowDestroyed(remaining: 0)
        }
        if shutdownSequence?.phase == .readyToShutdown { resumeShutdownWaiter() }
    }

    private func resumeShutdownWaiter() {
        let waiter = shutdownWaiter
        shutdownWaiter = nil
        waiter?.resume(returning: ())
    }
}
