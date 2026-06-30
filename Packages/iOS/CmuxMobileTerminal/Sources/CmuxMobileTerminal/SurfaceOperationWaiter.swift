import Foundation

@MainActor
final class SurfaceOperationWaiter {
    private var didResume = false

    func resume(
        returning result: Bool,
        continuation: CheckedContinuation<Bool, Never>
    ) -> Bool {
        guard !didResume else { return false }
        didResume = true
        continuation.resume(returning: result)
        return true
    }
}
