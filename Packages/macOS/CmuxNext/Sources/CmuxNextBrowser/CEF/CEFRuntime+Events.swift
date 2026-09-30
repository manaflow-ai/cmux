import AppKit
import Foundation

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
        DispatchQueue.main.async { MainActor.assumeIsolated { CEFRuntime.from(address)?.handle(event) } }
        return
    }
    MainActor.assumeIsolated {
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
    return MainActor.assumeIsolated {
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeKey(event, browser: browser) ? 1 : 0
    }
}

/// C entry before a DevTools browser sees a key down; `browser` is the
/// inspected page.
let cefDevToolsKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    guard let context, let nsEvent else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated {
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

    func handle(_ event: CEFShimEvent) {
        switch event {
        case .contextInitialized:
            logger.info("CEF context initialized")
        case .afterCreated(let browser, let request, let window, let created):
            browserCreated(browser, request: request, window: window, created: created)
        case .chromeCommand(let browser, let command):
            chromeWindowCommandBlocked(command, browser: browser)
        case .beforeClose(let browser):
            browserClosed(browser)
        case .devToolsResult(let browser, let messageID, let success, let json):
            devToolsCalls.resolve(CEFDevToolsKey(browser: browser, message: messageID),
                                  with: success ? .success(json) : .failure(BrowserTabError.javaScript(json)))
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
            tabsByBrowser[browser]?.devToolsWillOpen()
        case .devToolsOpened(let browser, let devTools, let docked):
            tabsByBrowser[browser]?.devToolsOpened(browser: devTools, docked: docked)
        case .devToolsClosed(let browser, let devTools):
            tabsByBrowser[browser]?.devToolsClosed(browser: devTools)
        case .unknown:
            break
        default:
            if let browser = event.browserID, let tab = tabsByBrowser[browser] {
                tab.handle(event)
            }
        }
    }

    /// App content shortcuts first (through the host's key router, which
    /// also runs extension shortcuts), then, for Option chords the router
    /// does not see, the profile's extension shortcuts (`chrome.commands`),
    /// which Chromium would dispatch from the Chrome toolbar cmux hides.
    func routeKey(_ event: NSEvent, browser: Int32) -> Bool {
        guard event.type == .keyDown, let tab = tabsByBrowser[browser] else { return false }
        if !event.modifierFlags.isDisjoint(with: [.command, .control]), let router = tab.keyRouter,
           router.browserTab(tab, keyEquivalent: event) == .handledByHost {
            return true
        }
        guard !event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              tab.keyRouter?.pageOwnsAllKeys(tab) != true else { return false }
        let store = extensionStore(for: tab.profileID)
        guard let command = store.command(matching: event) else { return false }
        return store.run(command, in: tab)
    }

    func routeDevToolsKey(_ event: NSEvent, inspected browser: Int32) -> Bool {
        guard event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control]),
              let tab = tabsByBrowser[browser], let router = tab.keyRouter else { return false }
        return router.browserTab(tab, devToolsKeyEquivalent: event) == .handledByHost
    }

    // MARK: Browser lifetime

    private func browserCreated(_ browser: Int32, request: Int32, window: Int32, created: CEFCreatedBy) {
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
        adoptOrphan(browser: browser, window: window, created: created)
    }

    func register(_ tab: CEFTab, browser: Int32) {
        tabsByBrowser[browser] = tab
        tab.attach(browser: browser)
    }

    private func browserClosed(_ browser: Int32) {
        if let tab = tabsByBrowser.removeValue(forKey: browser) {
            tab.browserDidClose()
        } else {
            // Never registered: drop a pending adoption of it.
            adoptions.closedUnregistered(browser)
            unplaced[browser] = nil
        }
        devToolsCalls.failAll(where: { $0.browser == browser }, with: BrowserTabError.closed)
        siteReplies.failAll(where: { siteReplyBrowsers[$0] == browser }, with: BrowserTabError.closed)
        shutdownSequence?.browserClosed(remaining: tabsByBrowser.count)
        shutdownProgressed()
        pump?.scheduleNow()
    }

    private func forkTabEvent(_ kind: CEFForkTabEvent, browser: Int32, window: Int32, value: Int) {
        switch kind {
        case .extensionActionsChanged, .inserted, .removed:
            if kind == .inserted { placeUnplaced(browser: browser, window: window) }
            for host in hosts.values where host.owns(window: window) || host.containsBrowser(inWindow: window) {
                host.refreshExtensionActions()
            }
            if kind == .extensionActionsChanged { refreshExtensionStores(window: window, browser: browser) }
        case .extensionsChanged:
            refreshExtensionStores(window: window, browser: browser)
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
            if let tab = tabsByBrowser[browser], tab.host.visibleTab !== tab {
                Task { @MainActor [weak tab] in
                    guard let tab, tab.host.visibleTab !== tab else { return }
                    tab.emit(.activate)
                }
            }
        case .devToolsDockSide:
            tabsByBrowser[browser]?.devToolsDockSideChosen(value)
        case .foreignBrowserBlocked:
            logger.error("Chromium created a window outside cmux (type \(value)); the fork hid it")
        case .moved, .unknown:
            break
        }
    }

    // MARK: DevTools

    /// Longest wait for an in-process DevTools result.
    static let devToolsTimeout: Duration = .seconds(5)

    /// Runs a DevTools method in process and returns its JSON result, or
    /// throws `timedOut` when no result arrives within `devToolsTimeout`.
    func devTools(_ browser: Int32, method: String, params: [String: Any] = [:]) async throws -> String {
        guard let shim else { throw BrowserTabError.closed }
        let message = shim.devToolsCall(browser, method, CEFDevToolsResult.params(params))
        guard message != 0 else { throw BrowserTabError.closed }
        let timeout = Self.devToolsTimeout
        return try await devToolsCalls.reply(for: CEFDevToolsKey(browser: browser, message: message), timeout: timeout) {
            BrowserTabError.timedOut("DevTools \(method) (\(timeout))")
        }
    }

    // MARK: Quit

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
        var sequence = CEFShutdownSequence(liveBrowsers: tabsByBrowser.count, windows: Int(shim.windowCount()))
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

    /// Called after every close/destroy event during shutdown.
    func shutdownProgressed() {
        guard shutdownSequence != nil else { return }
        if let shim, shim.windowCount() == 0, tabsByBrowser.isEmpty {
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
             .loadStart(let b, _), .loadEnd(let b, _), .loadError(let b, _, _, _), .progress(let b, _),
             .fullscreen(let b, _), .findResult(let b, _, _, _), .closeRequested(let b), .popup(let b, _, _),
             .afterCreated(let b, _, _, _), .beforeClose(let b), .chromeCommand(let b, _), .devToolsResult(let b, _, _, _), .tab(_, let b, _, _),
             .reply(let b, _, _, _), .contextMenu(let b, _, _, _, _, _),
             .devToolsWillOpen(let b), .devToolsOpened(let b, _, _), .devToolsClosed(let b, _),
             .renderTerminated(let b, _, _, _), .renderUnresponsive(let b), .renderResponsive(let b):
            b
        case .contextInitialized, .unknown:
            nil
        }
    }
}
