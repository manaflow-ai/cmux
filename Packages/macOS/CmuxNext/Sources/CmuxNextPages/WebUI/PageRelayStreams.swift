/// The listeners of a page relay channel as a page's streams drive them: the app's
/// `PageRelayChannel`, a fake in tests.
@MainActor
public protocol PageRelayListeners: AnyObject {
    /// Listener `id` delivers nothing and no longer keeps the channel's connection (the page froze).
    func pauseListener(_ id: UInt64)
    /// Listener `id` delivers again and keeps the connection; a closed connection opens again with
    /// the page's next call (its re-read after the resync), before that call goes out.
    func resumeListener(_ id: UInt64)
    /// Listener `id` ends (the page's unsubscribe).
    func stopListener(_ id: UInt64)
}

/// One provider's relay streams (the app's `DaemonPageRelay`), paused while the page is frozen.
/// A freeze pauses every stream's channel listener, so a frozen page keeps no
/// daemon listen and its channel closes when idle; a thaw resumes each and gives it one
/// `{resync: true}`, which the page answers with a fresh read of what it missed. Chrome's WebUI
/// handlers drop their observers in `OnJavascriptDisallowed` and re-read in `OnJavascriptAllowed`
/// in the same way (content/public/browser/web_ui_message_handler.h). Everything runs in the
/// caller's turn: the resyncs reach the router before it releases its hold.
@MainActor
public final class PageRelayStreams {
    private struct Stream {
        let channel: any PageRelayListeners
        let listener: UInt64
        let resync: @MainActor () -> Void
    }

    private var streams: [UInt64: Stream] = [:]
    private var nextID: UInt64 = 0
    private var frozen = false

    public init() {}

    /// Adds a stream on `channel`'s listener `listener` (already listening) and returns its stop.
    /// A stream added while the page is frozen pauses at once and resyncs on the thaw.
    ///
    /// - Parameters:
    ///   - listener: The channel's listener id.
    ///   - channel: The channel that holds it.
    ///   - resync: Sends the stream's `{resync: true}`.
    public func add(listener: UInt64, on channel: any PageRelayListeners,
                    resync: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        streams[id] = Stream(channel: channel, listener: listener, resync: resync)
        if frozen { channel.pauseListener(listener) }
        return { [weak self] in
            guard let stream = self?.streams.removeValue(forKey: id) else { return }
            stream.channel.stopListener(stream.listener)
        }
    }

    /// The page froze: every stream's listener pauses. A second freeze does nothing.
    public func freeze() {
        guard !frozen else { return }
        frozen = true
        for stream in streams.values { stream.channel.pauseListener(stream.listener) }
    }

    /// The page thawed: each listener resumes, then its stream gets one resync, in stream order.
    /// Does nothing on a page that is not frozen.
    public func thaw() {
        guard frozen else { return }
        frozen = false
        for id in streams.keys.sorted() {
            guard let stream = streams[id] else { continue }
            stream.channel.resumeListener(stream.listener)
            stream.resync()
        }
    }

    /// The streams the provider has open.
    public var count: Int { streams.count }
}
