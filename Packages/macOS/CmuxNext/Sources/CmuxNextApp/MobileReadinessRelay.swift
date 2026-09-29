import CmuxNextMobile
import Synchronization

/// Hands usable phone connections to whoever publishes them (the control
/// socket's `mobile.rpc.ready` event). The host is created before the
/// socket exists, so it reports here and the sink is installed later.
nonisolated final class MobileReadinessRelay: Sendable {
    private let sink = Mutex<(@Sendable (MobileUsableSession) -> Void)?>(nil)

    func install(_ handler: @escaping @Sendable (MobileUsableSession) -> Void) {
        sink.withLock { $0 = handler }
    }

    func report(_ session: MobileUsableSession) {
        sink.withLock { $0 }?(session)
    }
}
