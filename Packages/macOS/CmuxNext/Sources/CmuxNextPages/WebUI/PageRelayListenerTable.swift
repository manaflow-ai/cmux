public import CmuxNextSettings
public import CmuxNextWakeups

/// The page streams listening on one page relay channel (p05-ipc-109): the daemon event each hears,
/// its delivery, and whether its frozen page paused it. The channel reads its connection off the
/// main actor and hands each frame's events here in one batch (``FrameOutbox``). A live listener
/// keeps the channel's connection (``PageRelayIdleClose``); a paused one hears nothing and does not
/// keep it, and its page's thaw resyncs it (``PageRelayStreams``).
public final class PageRelayListenerTable: PageRelayListeners {
    /// One daemon event as the page gets it: its name (`history-changed`) and its line as the daemon
    /// sent it, JSON text the app never decodes. The page parses it and ignores its `event` member.
    public typealias Event = (name: String, json: String)

    private struct Listener {
        let event: String
        let deliver: @MainActor (JSONValue) -> Void
        var paused = false
    }

    private var listeners: [UInt64: Listener] = [:]
    private var lastID: UInt64 = 0
    private let idle: PageRelayIdleClose

    /// - Parameter idle: The channel's idle close: a live listener is one of its uses.
    public init(idle: PageRelayIdleClose) {
        self.idle = idle
    }

    /// Adds a live listener of `event`; it keeps the connection until it pauses or stops.
    ///
    /// - Parameters:
    ///   - event: The daemon subscribe event it hears.
    ///   - deliver: Takes each of those events as a JSON text string (the stream is
    ///     ``PageEventEncoding/jsonText``), and the value `{resync: true}` after events were lost.
    /// - Returns: The listener's id for ``pauseListener(_:)``, ``resumeListener(_:)`` and ``stopListener(_:)``.
    public func add(event: String, deliver: @escaping @MainActor (JSONValue) -> Void) -> UInt64 {
        lastID += 1
        listeners[lastID] = Listener(event: event, deliver: deliver)
        idle.begin()
        return lastID
    }

    /// One frame's events, in arrival order, each to the live listeners of its name. After a `gap`
    /// (events were lost: a reconnect or an overflow) every live listener re-reads instead.
    public func deliver(_ events: [Event], gap: Bool) {
        if gap { resync() }
        for event in events {
            for listener in listeners.values where listener.event == event.name && !listener.paused {
                listener.deliver(.string(event.json))
            }
        }
    }

    /// Every live listener re-reads; a paused one resyncs on its page's thaw instead.
    public func resync() {
        for listener in listeners.values where !listener.paused { listener.deliver(["resync": true]) }
    }

    public func pauseListener(_ id: UInt64) {
        guard listeners[id]?.paused == false else { return }
        listeners[id]?.paused = true
        idle.end()
    }

    public func resumeListener(_ id: UInt64) {
        guard listeners[id]?.paused == true else { return }
        listeners[id]?.paused = false
        idle.begin()
    }

    public func stopListener(_ id: UInt64) {
        guard let listener = listeners.removeValue(forKey: id) else { return }
        if !listener.paused { idle.end() }
    }

    /// The listeners, paused ones included.
    public var count: Int { listeners.count }
}
