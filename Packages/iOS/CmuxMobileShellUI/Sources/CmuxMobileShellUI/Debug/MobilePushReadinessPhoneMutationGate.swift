#if os(iOS) && DEBUG
import Foundation

/// Test-only signal for holding a push mutation open until XCUITest observes
/// the optimistic, disabled toggle state.
@MainActor
final class MobilePushReadinessPhoneMutationGate {
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release()
            }
        }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
#endif
