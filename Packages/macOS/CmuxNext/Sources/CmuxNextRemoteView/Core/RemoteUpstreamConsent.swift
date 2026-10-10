/// The per-session consent for upstream media (the C4b contract in
/// plans/cmux-next/coordination/remote-desktop.md), owned by the session's
/// transport:
/// 1. a kind is requested only from the user's explicit action for it in
///    this session (`request`), which also asked macOS for the permission;
///    a denied permission means no consent;
/// 2. the host must offer `up_media` and `stream.open` in its welcome, and
///    must answer `stream_opened`, before a sender exists (`opened`);
/// 3. `active` drives the visible indicator; its stop control (`stop`)
///    revokes at once and frees the sender;
/// 4. session end, tab close, host stop and disconnect call `endSession`,
///    which revokes and frees every sender and refuses later requests.
/// Nothing is remembered across sessions: a new session starts empty.
/// Not thread-safe: the transport's queue owns it.
public nonisolated final class RemoteUpstreamConsent {
    /// Why a request did not start.
    public enum Refusal: Error, Sendable, Hashable {
        /// The host's welcome does not list `up_media` and `stream.open`.
        case notOffered
        /// The user denied the macOS permission.
        case permissionDenied
        /// The session ended.
        case sessionEnded
    }

    /// What `opened` did with a `stream_opened`.
    public enum Opened {
        /// Not a stream this session asked for (or it was stopped meanwhile): ignore it.
        case ignored
        /// The sender exists and holds consent.
        case started(RemoteRdUpstream)
        /// The core could not create the sender: send `stream_close`.
        case failed(stream: UInt16)
    }

    /// Upstream stream ids start here, apart from the host's display streams.
    public static let firstStream: UInt16 = 100

    public let isOffered: Bool
    private var nextStream = RemoteUpstreamConsent.firstStream
    private var pending: [UInt16: RemoteUpstreamKind] = [:]
    private var senders: [RemoteUpstreamKind: RemoteRdUpstream] = [:]
    private var ended = false

    /// `welcomeCaps`: the caps of the host's welcome.
    public init(welcomeCaps: [String]) {
        isOffered = welcomeCaps.contains("up_media") && welcomeCaps.contains("stream.open")
    }

    /// The kinds that hold consent now (the indicator shows each one).
    public var active: Set<RemoteUpstreamKind> { Set(senders.keys) }

    /// The kinds waiting for the host's answer.
    public var requested: Set<RemoteUpstreamKind> { Set(pending.values) }

    /// The sender of a consented kind.
    public func sender(_ kind: RemoteUpstreamKind) -> RemoteRdUpstream? { senders[kind] }

    /// Every sender with consent, for feedback routing and sending.
    public var activeSenders: [RemoteRdUpstream] { Array(senders.values) }

    /// Call only from the user's explicit action for `kind` (a pane button),
    /// after that action asked macOS for the permission. Returns the
    /// `stream_open` to send, or nil when the kind is already requested or
    /// active.
    public func request(_ kind: RemoteUpstreamKind, permissionGranted: Bool) throws(Refusal) -> RemoteRdStreamOpen? {
        guard !ended else { throw .sessionEnded }
        guard isOffered else { throw .notOffered }
        guard permissionGranted else { throw .permissionDenied }
        guard senders[kind] == nil, !pending.values.contains(kind) else { return nil }
        let stream = nextStream
        nextStream &+= 1
        if nextStream < Self.firstStream { nextStream = Self.firstStream }
        pending[stream] = kind
        return RemoteRdStreamOpen(stream: stream, kind: kind.streamKind, codec: kind.codec)
    }

    /// The host answered `stream_opened`: `make` creates the sender for the
    /// kind and stream, which then gets consent.
    public func opened(stream: UInt16, make: (RemoteUpstreamKind, UInt16) -> RemoteRdUpstream?) -> Opened {
        guard !ended, let kind = pending.removeValue(forKey: stream) else { return .ignored }
        guard let sender = make(kind, stream), sender.kind == kind, sender.stream == stream else {
            return .failed(stream: stream)
        }
        sender.setConsent(true)
        senders[kind] = sender
        return .started(sender)
    }

    /// The host answered `stream_refused`; returns the kind it refused.
    @discardableResult
    public func refused(stream: UInt16) -> RemoteUpstreamKind? {
        pending.removeValue(forKey: stream)
    }

    /// The host closed a stream (`stream_close`, for example after it took
    /// control away): revokes and frees that sender.
    @discardableResult
    public func closedByHost(stream: UInt16) -> RemoteUpstreamKind? {
        if let kind = pending.removeValue(forKey: stream) { return kind }
        guard let kind = senders.first(where: { $0.value.stream == stream })?.key else { return nil }
        revoke(kind)
        return kind
    }

    /// The indicator's stop control: revokes at once and frees the sender
    /// (or forgets a request still waiting). Returns the stream to close.
    @discardableResult
    public func stop(_ kind: RemoteUpstreamKind) -> UInt16? {
        if let stream = pending.first(where: { $0.value == kind })?.key {
            pending[stream] = nil
            return stream
        }
        return revoke(kind)
    }

    /// Session end, tab close, host stop or disconnect: revokes every kind,
    /// frees every sender and refuses later requests. Returns the streams
    /// to close (when the carrier is still up).
    @discardableResult
    public func endSession() -> [UInt16] {
        ended = true
        var streams = Array(pending.keys)
        pending.removeAll()
        for kind in Array(senders.keys) {
            if let stream = revoke(kind) { streams.append(stream) }
        }
        return streams.sorted()
    }

    @discardableResult
    private func revoke(_ kind: RemoteUpstreamKind) -> UInt16? {
        guard let sender = senders.removeValue(forKey: kind) else { return nil }
        sender.setConsent(false)
        return sender.stream
    }
}
