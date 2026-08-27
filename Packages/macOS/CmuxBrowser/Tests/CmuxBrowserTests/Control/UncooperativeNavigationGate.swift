import Foundation

/// A cancellation-insensitive await used to prove timeout ownership does not await its child.
@MainActor
final class UncooperativeNavigationGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
