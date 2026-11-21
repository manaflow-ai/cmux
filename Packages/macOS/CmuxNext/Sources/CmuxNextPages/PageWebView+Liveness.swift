public import Foundation

/// The page's half of the agent-chat liveness watchdog (App Health's `liveness` parts, whose rule
/// is cmux-health-core's): a host-to-page ping that needs no input, and the end of a renderer it
/// proved hung. A page beats only while something happens in it and stops at rest, so a chat
/// stuck in a synchronous loop read as resting until now; Chromium's own hang report needs an
/// unanswered input event, so an untouched hung chat never reported either.
extension PageWebView {
    /// Whether the watchdog times this page: an agent chat shown in Chromium.
    public var isTimedForLiveness: Bool { descriptor.isAgentPage && chromiumPage != nil && !isClosed }

    /// The one renderer hosting the page (Chromium's client id); nil when unknown.
    public var rendererClientID: Int32? { chromiumPage?.rendererProcess?.rendererClientID }

    /// That renderer's pid; nil when unknown.
    public var rendererProcessID: Int32? { chromiumPage?.rendererProcess?.rendererProcessID }

    /// Whether the page's DevTools are open (a breakpoint may hold its main thread on purpose).
    public var isBeingDebugged: Bool { chromiumPage?.rendererProcess?.isBeingDebugged ?? false }

    /// The page-to-host messages its bridge took (the page's last message is the latest of them),
    /// with the last one's name and uptime; zero before any.
    public var pageMessages: (count: UInt64, lastName: String?, lastUptime: TimeInterval?) {
        guard let bridge = chromiumSession?.bridge else { return (0, nil, nil) }
        return (bridge.messagesReceived, bridge.lastMessageName, bridge.lastMessageUptime)
    }

    /// One round trip to the page's main thread (`Runtime.evaluate` of `0`, which runs there),
    /// bounded by `timeout` so the call always ends: true when it answered, in any words.
    public func pingMainThread(timeout: Duration) async -> Bool {
        guard let page = chromiumPage, !isClosed else { return false }
        do {
            _ = try await page.devTools("Runtime.evaluate", params: ["expression": "0", "silent": true], timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    /// The watchdog is about to end this page's renderer: its end is a repair, not a crash, so the
    /// page reloads in a new renderer even under a host that shows the crash notice, and once the
    /// new document loads its host shows `notice` (``onRendererRestarted``).
    public func prepareForRendererEnd(notice: String) {
        guard !isClosed else { return }
        rendererRestartPending = true
        pendingRestartNotice = notice
    }

    /// The end did not happen: the page keeps its crash rule and shows no notice.
    public func cancelRendererEnd() {
        rendererRestartPending = false
        pendingRestartNotice = nil
    }

    /// Ends the one renderer `pages` share, by force (``PageRendererProcess/endRenderer()``):
    /// every page is marked first to reload as a repair and to show `notice` once it loads again,
    /// then the first open page's renderer ends (and every page in it with it); when nothing
    /// ended, the marks are taken back. Returns the pid ended (0: ended, pid unknown), or nil.
    public static func endHungRenderer(of pages: [PageWebView], notice: String) -> Int32? {
        for page in pages { page.prepareForRendererEnd(notice: notice) }
        let renderer = pages.lazy.filter { !$0.isClosed }.compactMap { $0.chromiumPage?.rendererProcess }.first
        guard let ended = renderer?.endRenderer() else {
            for page in pages { page.cancelRendererEnd() }
            return nil
        }
        return ended
    }

    /// This page in the watchdog's log line: who it is (``logIdentity``, else its page id), its
    /// pane, whether it shows, and its last page-to-host message (seq, name, age at `now`, in
    /// `systemUptime` seconds). Every page of a hung renderer is named: they share one main
    /// thread, so the host cannot tell which page's script holds it.
    public func livenessLogEntry(visible: Bool, now: TimeInterval) -> String {
        let messages = pageMessages
        let last = messages.lastUptime.map { String(format: "%.0f s ago", now - $0) } ?? "never"
        let who = logIdentity?() ?? "page \(descriptor.id)"
        return "[\(who) pane=\(healthPartID) \(visible ? "visible" : "hidden") lastMessage=#\(messages.count) \(messages.lastName ?? "none") \(last)]"
    }
}
