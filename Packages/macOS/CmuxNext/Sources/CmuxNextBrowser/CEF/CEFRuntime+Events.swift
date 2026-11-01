import AppKit
import Foundation
import os

/// Faults from shim callbacks that arrive off the CEF UI (main) thread.
private let callbackLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

/// C entry for shim events (main thread).
let cefEventCallback: CEFShimLibrary.EventFn = { context, kind, browser, request, a, b, s1, s2 in
    guard let context else { return }
    let event = CEFShimEvent(
        kind: kind, browser: browser, request: request, a: a, b: b,
        s1: s1.map { String(cString: $0) } ?? "", s2: s2.map { String(cString: $0) } ?? ""
    )
    let address = UInt(bitPattern: context)
    // The shim emits on the CEF UI thread, which is the main thread. If a
    // future shim path emits elsewhere, hop instead of trapping in
    // assumeIsolated (the strings are already copied into `event`).
    guard Thread.isMainThread else {
        DispatchQueue.main.async { MainActor.assumeIsolated { CEFRuntime.from(address)?.handle(event) } } // main-proof: a DispatchQueue.main block runs on the main thread
        return
    }
    MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        CEFRuntime.from(address)?.handle(event)
    }
}

/// C entry before the page sees a key down: app shortcuts win.
let cefKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    // Keys arrive on the main thread; off it, let the page have the key
    // rather than trap in assumeIsolated.
    guard let context, let nsEvent, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeKey(event, browser: browser) ? 1 : 0
    }
}

/// C entry after the page left a key down unhandled: the host's held shortcut runs.
let cefUnhandledKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    // Keys arrive on the main thread; off it, Chromium keeps the key.
    guard let context, let nsEvent, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeUnhandledKey(event, browser: browser) ? 1 : 0
    }
}

/// C entry before a DevTools browser sees a key down; `browser` is the
/// inspected page.
let cefDevToolsKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    guard let context, let nsEvent else { return 0 }
    // Keys arrive on the main thread; off it, the DevTools page keeps the key.
    guard Thread.isMainThread else {
        callbackLogger.fault("DevTools key callback off the main thread; the key goes to the page")
        return 0
    }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeDevToolsKey(event, inspected: browser) ? 1 : 0
    }
}

extension CEFRuntime {
    /// The runtime behind a callback context (an unretained pointer; the
    /// runtime lives for the rest of the process once started).
    static func from(_ address: UInt) -> CEFRuntime? {
        UnsafeMutableRawPointer(bitPattern: address).map { Unmanaged<CEFRuntime>.fromOpaque($0).takeUnretainedValue() }
    }

    /// The pump's cross-thread gate behind a callback context, from any thread (a `nonisolated let`
    /// of the runtime, which lives for the rest of the process once started).
    nonisolated static func pumpGate(at address: UInt) -> CEFPumpCrossThreadGate? {
        UnsafeMutableRawPointer(bitPattern: address).map { Unmanaged<CEFRuntime>.fromOpaque($0).takeUnretainedValue().pumpGate }
    }

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .contextInitialized:
            logger.info("CEF context initialized")
        case .afterCreated(let browser, let request, let window, let created):
            browserCreated(browser, request: request, window: window, created: created)
        case .popup:
            // AFTER_CREATED of the popup's tab carries its URL, disposition
            // and gesture (the shim's pending popups).
            break
        case .chromeCommand(let browser, let command):
            chromeWindowCommandBlocked(command, browser: browser)
        case .beforeClose(let browser):
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
        case .pageDragEnter(let browser, let pathsJSON):
            if let tab = tabsByBrowser[browser], let entered = tab.pageFilesDragged { entered(CEFTab.dragPaths(pathsJSON)) }
        case .fileDialog(let browser, let dialogID, let mode, _, let defaultPath):
            // Only while an agent's file offer stands (`CEFRuntime+FileDialogs`).
            answerFileDialog(dialogID, mode: mode, defaultPath: defaultPath, tab: tabsByBrowser[browser])
        case .devToolsResult(let browser, let messageID, let success, let json):
            let key = CEFDevToolsKey(browser: browser, message: messageID)
            let result: Result<String, any Error> = success ? .success(json) : .failure(BrowserTabError.javaScript(json))
            if !devToolsCalls.resolve(key, with: result) {
                // A synchronous answer: devTools(_:method:) takes it when the shim call returns.
                synchronousDevToolsResults?[key] = result
            }
        case .reply(_, let id, let value, let json):
            let reply = CEFSiteReply(value: value, json: json)
            if !siteReplies.resolve(id, with: .success(reply)), siteReplyBrowsers[id] != nil {
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
        case .installPrompt(let browser, let promptID, let json):
            extensionPrompts.arrived(promptID: promptID, browser: browser, json: json)
        case .download(let event):
            downloads.handle(event)
        case .omniboxSuggestions(let requestID, let extensionID, let json):
            omniboxKeywords.suggestionsArrived(requestID: requestID, extensionID: extensionID, json: json)
        case .authCallback(let browser, let url):
            signInCallbacks.stopped(browser: browser, url: url)
        case .bookmarks(let json, let path):
            CEFBookmarkBridge.shared.arrived(json: json, cachePath: path)
        case .unknown:
            break
        default:
            if let browser = event.browserID, let tab = tabsByBrowser[browser] {
                #if DEBUG
                CEFEventTrace.record(browser, event)
                #endif
                tab.handle(event)
            }
        }
    }

    /// App content shortcuts first (through the host's key router, which
    /// also runs extension shortcuts), then, for Option chords the router
    /// does not see, the profile's extension shortcuts (`chrome.commands`),
    /// which Chromium would dispatch from the Chromium toolbar cmux hides.
    func routeKey(_ event: NSEvent, browser: Int32) -> Bool {
        guard event.type == .keyDown, let tab = tabsByBrowser[browser] else { return false }
        if !event.modifierFlags.isDisjoint(with: [.command, .control]), let router = tab.keyRouter,
           router.browserTab(tab, keyEquivalent: event) == .handledByHost {
            return true
        }
        guard !event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              tab.keyRouter?.pageOwnsAllKeys(tab) != true else { return false }
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
        windowRequests.linkClicks.startRecordingClicks { [weak self] in self?.windowRequests.clickTargets() ?? [] }
        swipeNavigation.start()
        tabsByBrowser[browser] = tab
        tab.attach(browser: browser)
        accessibility.attached(browser)
        signInCallbacks.attached(tab)
    }

    private func browserClosed(_ browser: Int32) {
        windowRequests.linkClicks.forget(opener: browser)
        if let tab = tabsByBrowser.removeValue(forKey: browser) {
            tab.browserDidClose(closesTab: shutdownSequence == nil)
        } else {
            // Never registered: drop a pending adoption of it.
            orphans.closedUnregistered(browser)
        }
        devToolsCalls.failAll(where: { $0.browser == browser }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { siteReplyBrowsers[$0] == browser }, with: BrowserTabError.closed)
        failEvaluations(of: browser)
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
            // Chromium (an extension) switched the window's tab: cmux selects
            // it. Our own cmux_tab_activate echoes for the visible tab.
            // The event arrives inside Chromium's tab strip notification, which
            // forbids re-entrant tab strip changes (cmux_tab_activate); the
            // host selects the tab on the next main-actor turn.
            // An echo of our own activation (or of the tab's creation) that
            // lands after the user selected another tab must not select this
            // one again: that stale completion jumped the selection back.
            if let tab = tabsByBrowser[browser], tab.host.visibleTab !== tab {
                guard tab.host.isForeignActivation(of: tab) else {
                    tab.host.lifecycleTrace.record(tab.id, "chromium-activated echo dropped")
                    return
                }
                Task { @MainActor [weak tab] in
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
        case .moved, .unknown:
            break
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
        shim.closeAll()
        pump?.pumpNow()
        shutdownProgressed()
        if shutdownSequence?.phase != .readyToShutdown {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                shutdownWaiter = continuation
                shutdownTimeout = Task { @MainActor [weak self] in
                    // wakeup-allow: one-shot shutdown deadline, cancelled when Chromium reports closed
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.resumeShutdownWaiter()
                }
            }
        }
        shutdownTimeout?.cancel()
        shutdownTimeout = nil
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
        waiter?.resume()
    }
}

extension CEFShimEvent {
    var browserID: Int32? {
        switch self {
        case .address(let b, _), .title(let b, _), .favicon(let b, _), .loadingState(let b, _, _, _),
             .loadStart(let b, _, _), .loadEnd(let b, _), .loadError(let b, _, _, _, _), .progress(let b, _),
             .fullscreen(let b, _), .findResult(let b, _, _, _), .closeRequested(let b), .popup(let b, _, _, _),
             .afterCreated(let b, _, _, _), .beforeClose(let b), .chromeCommand(let b, _), .devToolsResult(let b, _, _, _), .tab(_, let b, _, _),
             .reply(let b, _, _, _), .contextMenu(let b, _, _, _, _, _),
             .devToolsWillOpen(let b), .devToolsOpened(let b, _, _), .devToolsClosed(let b, _),
             .renderTerminated(let b, _, _, _), .renderUnresponsive(let b), .renderResponsive(let b),
             .navigationReroute(let b, _, _), .localFileHandoff(let b, _), .externalURL(let b, _, _), .keyUnhandled(let b, _, _), .installPrompt(let b, _, _), .takeFocus(let b, _),
             .devToolsMessage(let b, _), .authCallback(let b, _), .permissionPrompt(let b, _, _, _), .permissionDismissed(let b, _), .passwordPrompt(let b, _, _),
             .beforeUnloadDialog(let b, _, _), .beforeUnloadDismissed(let b), .pageResource(let b, _, _), .pageDragEnter(let b, _),
             .fileDialog(let b, _, _, _, _),
             .pageMessage(let b, _, _, _):
            b
        case .contextInitialized, .omniboxSuggestions, .preferenceChanged, .bookmarks, .download, .evaluateResult, .unknown:
            nil
        }
    }
}
