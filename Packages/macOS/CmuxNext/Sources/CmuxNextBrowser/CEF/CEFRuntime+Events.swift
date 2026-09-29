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
    MainActor.assumeIsolated {
        CEFRuntime.from(address)?.handle(event)
    }
}

/// C entry before the page sees a key down: app shortcuts win.
let cefKeyCallback: CEFShimLibrary.KeyFn = { context, browser, nsEvent in
    guard let context, let nsEvent else { return 0 }
    let address = UInt(bitPattern: context)
    let eventAddress = UInt(bitPattern: nsEvent)
    return MainActor.assumeIsolated {
        guard let runtime = CEFRuntime.from(address),
              let pointer = UnsafeMutableRawPointer(bitPattern: eventAddress) else { return 0 }
        let event = Unmanaged<NSEvent>.fromOpaque(pointer).takeUnretainedValue()
        return runtime.routeKey(event, browser: browser) ? 1 : 0
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
        case .afterCreated(let browser, let request, let window):
            browserCreated(browser, request: request, window: window)
        case .beforeClose(let browser):
            browserClosed(browser)
        case .devToolsResult(let browser, let messageID, let success, let json):
            guard let continuation = devToolsCalls.removeValue(forKey: CEFDevToolsKey(browser: browser, message: messageID)) else { return }
            if success {
                continuation.resume(returning: json)
            } else {
                continuation.resume(throwing: BrowserTabError.javaScript(json))
            }
        case .tab(let kind, let browser, let window, let value):
            forkTabEvent(kind, browser: browser, window: window, value: value)
        case .unknown:
            break
        default:
            if let browser = event.browserID, let tab = tabsByBrowser[browser] {
                tab.handle(event)
            }
        }
    }

    func routeKey(_ event: NSEvent, browser: Int32) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command),
              let tab = tabsByBrowser[browser], let router = tab.keyRouter else { return false }
        return router.browserTab(tab, keyEquivalent: event) == .handledByHost
    }

    // MARK: Browser lifetime

    private func browserCreated(_ browser: Int32, request: Int32, window: Int32) {
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
        guard let host = hosts.values.first(where: { $0.owns(window: window) || $0.containsBrowser(inWindow: window) }) else {
            logger.error("CEF browser \(browser) created in unknown window \(window)")
            shim?.close(browser)
            return
        }
        host.adoptChromiumTab(browser: browser)
    }

    func register(_ tab: CEFTab, browser: Int32) {
        tabsByBrowser[browser] = tab
        tab.attach(browser: browser)
    }

    private func browserClosed(_ browser: Int32) {
        if let tab = tabsByBrowser.removeValue(forKey: browser) {
            tab.browserDidClose()
        }
        for (key, continuation) in devToolsCalls where key.browser == browser {
            devToolsCalls[key] = nil
            continuation.resume(throwing: BrowserTabError.closed)
        }
        shutdownSequence?.browserClosed(remaining: tabsByBrowser.count)
        pump?.schedule(after: 0)
    }

    private func forkTabEvent(_ kind: CEFForkTabEvent, browser: Int32, window: Int32, value: Int) {
        switch kind {
        case .extensionActionsChanged, .inserted, .removed:
            for host in hosts.values where host.owns(window: window) || host.containsBrowser(inWindow: window) {
                host.refreshExtensionActions()
            }
        case .extensionPopupClosed:
            tabsByBrowser[browser]?.refreshExtensionActions()
        case .windowDestroyed:
            shutdownSequence?.windowDestroyed(remaining: value)
        case .activated, .moved, .unknown:
            break
        }
    }

    // MARK: DevTools

    /// Runs a DevTools method in process and returns its JSON result.
    func devTools(_ browser: Int32, method: String, params: [String: Any] = [:]) async throws -> String {
        guard let shim else { throw BrowserTabError.closed }
        let message = shim.devToolsCall(browser, method, CEFDevToolsResult.params(params))
        guard message != 0 else { throw BrowserTabError.closed }
        return try await withCheckedThrowingContinuation { continuation in
            devToolsCalls[CEFDevToolsKey(browser: browser, message: message)] = continuation
        }
    }

    // MARK: Quit

    /// Closes every browser, waits for the Chromium windows to be destroyed,
    /// then calls CefShutdown. Runs from `willTerminate`; it pumps the run
    /// loop itself with a bounded deadline because the app is about to exit.
    func shutdownBlocking(timeout: TimeInterval) {
        guard state == .ready, let shim else { return }
        var sequence = CEFShutdownSequence(liveBrowsers: tabsByBrowser.count, windows: Int(shim.windowCount()))
        sequence.begin()
        shutdownSequence = sequence
        shim.closeAll()
        let deadline = Date().addingTimeInterval(timeout)
        while shutdownSequence?.phase != .readyToShutdown, Date() < deadline {
            pump?.pumpNow()
            // Waits for the next CEF task or timer, not a fixed sleep.
            CFRunLoopRunInMode(.defaultMode, CEFPumpPolicy.maxDelay, true)
            if shim.windowCount() == 0, tabsByBrowser.isEmpty {
                shutdownSequence?.windowDestroyed(remaining: 0)
            }
        }
        if shutdownSequence?.phase != .readyToShutdown {
            logger.error("CEF shutdown timed out; exiting without CefShutdown")
            pump?.stop()
            state = .shutDown
            return
        }
        pump?.stop()
        shim.shutdown()
        state = .shutDown
        logger.notice("CEF shutdown complete")
    }
}

extension CEFShimEvent {
    var browserID: Int32? {
        switch self {
        case .address(let b, _), .title(let b, _), .favicon(let b, _), .loadingState(let b, _, _, _),
             .loadStart(let b, _), .loadEnd(let b, _), .loadError(let b, _, _, _), .progress(let b, _),
             .fullscreen(let b, _), .findResult(let b, _, _, _), .closeRequested(let b), .popup(let b, _, _),
             .afterCreated(let b, _, _), .beforeClose(let b), .devToolsResult(let b, _, _, _), .tab(_, let b, _, _):
            b
        case .contextInitialized, .unknown:
            nil
        }
    }
}
