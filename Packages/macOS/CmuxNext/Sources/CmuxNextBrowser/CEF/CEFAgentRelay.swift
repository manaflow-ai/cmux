import Foundation

/// What a raw DevTools send did (`cmux_shim_devtools_send`).
public nonisolated enum CEFDevToolsRawSend: Hashable, Sendable {
    case sent
    /// The tab has no Chromium browser (never shown, or closed).
    case noBrowser
    /// The shim refused the message (not a JSON object, an "id" below 2^30,
    /// or Chromium refused it).
    case refused
}

/// The browser host's raw DevTools relay of one CEF tab
/// (plans/cmux-next/browser-host.md, "CEF relay"). The relay owns every raw
/// id (>= 2^30, `CEFDevToolsRawMessage`): no other app code calls
/// `cmux_shim_devtools_send`. The shim header does not change, so the shim
/// ABI identity stays the same.
public final class CEFAgentRelay {
    private unowned let tab: CEFTab
    private var sink: ((String) -> Void)?
    private var onEnd: (() -> Void)?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(tab: CEFTab) { self.tab = tab }

    /// Starts relaying (`onMessage` set): every raw DevTools message of the
    /// tab's browser (replies to `send` and the protocol events of the
    /// domains the relay turned on) goes to `onMessage`, and `onEnd` runs
    /// once when the browser goes away. Nil stops the relay. A relay started
    /// before the browser exists takes effect when it is created.
    public func set(onMessage: ((String) -> Void)?, onEnd: (() -> Void)?) {
        sink = onMessage
        self.onEnd = onMessage == nil ? nil : onEnd
        if let browser = tab.browserID { tab.runtime.shim?.devToolsWatchEvents(browser, onMessage == nil ? 0 : 1) }
    }

    /// Sends one raw DevTools message; its "id" must be a raw id (>= 2^30).
    public func send(_ message: String) -> CEFDevToolsRawSend {
        guard !tab.isClosed, let browser = tab.browserID, let shim = tab.runtime.shim else { return .noBrowser }
        switch message.withCString({ shim.devToolsSend(browser, $0) }) {
        case 1: return .sent
        case 0: return .noBrowser
        default: return .refused
        }
    }

    /// True once the Chromium browser exists.
    public var hasBrowser: Bool { tab.browserID != nil }

    /// Creates the Chromium browser of a tab that was never shown, in the
    /// background (the pane host's own creation path; nothing is shown and
    /// focus does not move). Agents drive hidden tabs.
    public func createBrowser() {
        guard !tab.isClosed else { return }
        tab.host.ensureCreated(tab)
    }

    /// Resumes with true once the browser exists, false when its creation
    /// failed or the tab closed.
    public func browserCreated() async -> Bool {
        if tab.browserID != nil { return true }
        if tab.isClosed { return false }
        return await withCheckedContinuation { waiters.append($0) }
    }

    // MARK: Tab lifetime (CEFTab)

    func deliver(_ json: String) { sink?(json) }

    func browserAttached() {
        resumeWaiters(true)
        if sink != nil, let browser = tab.browserID { tab.runtime.shim?.devToolsWatchEvents(browser, 1) }
    }

    func resumeWaiters(_ created: Bool) {
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: created) }
    }

    /// The browser closed: waiters fail and the relay hears the end once.
    func browserEnded() {
        resumeWaiters(false)
        let end = onEnd
        sink = nil
        onEnd = nil
        end?()
    }
}
