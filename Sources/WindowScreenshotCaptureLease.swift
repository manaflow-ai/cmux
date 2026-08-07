#if DEBUG
import CmuxFoundation

/// Keeps screenshot admission claimed until its asynchronous operation retires.
final class WindowScreenshotCaptureLease: Sendable {
    private let retireBackend: @Sendable () -> Void
    private let didRetire = AtomicBooleanGate(false)

    init(retireBackend: @escaping @Sendable () -> Void) {
        self.retireBackend = retireBackend
    }

    func retire() {
        guard didRetire.compareExchange(expected: false, desired: true) else {
            return
        }
        retireBackend()
    }
}
#endif
