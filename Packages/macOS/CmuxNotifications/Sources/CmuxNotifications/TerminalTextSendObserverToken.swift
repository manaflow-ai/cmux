import Foundation

/// Closure-backed ``TerminalTextSendCancellable`` wrapping a single readiness
/// observer or the timeout for ``TerminalTextSendCoordinator``.
///
/// Cancellation is idempotent: the stored teardown closure is cleared after the
/// first call, mirroring the legacy `cleanupObservers()` which only removed each
/// observer once. The app-side ``TerminalTextSendTarget`` conformer constructs
/// one of these per observer/timeout, handing in the backing teardown (a Combine
/// `AnyCancellable` cancel, an `NSObjectProtocol` observer removal, or a
/// `DispatchWorkItem` cancel) so the coordinator tears them down without knowing
/// the mechanism.
@MainActor
public final class TerminalTextSendObserverToken: TerminalTextSendCancellable {
    private var teardown: (() -> Void)?

    /// Creates a token that runs `teardown` exactly once on the first ``cancel()``.
    public init(_ teardown: @escaping () -> Void) {
        self.teardown = teardown
    }

    public func cancel() {
        teardown?()
        teardown = nil
    }
}
