import CmuxNextCompat

/// Hands usable phone connections to whoever publishes them (the control
/// socket's `mobile.rpc.ready` event). The host is created before the
/// socket exists, so it reports here and the sink is installed later.
public final class MobileReadinessRelay: Sendable {
    private let sink = Mutex<Sink?>(nil)

    /// Keep the Mutex value a struct so reading it cannot wrap the stored
    /// callback in another function reabstraction thunk.
    private struct Sink: Sendable {
        let report: @Sendable (MobileUsableSession) -> Void
    }

    /// A relay with no sink yet: reports are dropped until ``install(_:)``.
    public init() {}

    /// Sets where usable sessions go from now on.
    public func install(_ handler: @escaping @Sendable (MobileUsableSession) -> Void) {
        sink.withLock { $0 = Sink(report: handler) }
    }

    /// Hands `session` to the installed sink, if any.
    public func report(_ session: MobileUsableSession) {
        sink.withLock { $0?.report }?(session)
    }
}
