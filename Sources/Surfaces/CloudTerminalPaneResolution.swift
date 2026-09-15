import Foundation

/// The reserved pane's terminal identity, shared by shortcuts issued before
/// attachment completes. Closing or failing the parent settles its dependents.
@MainActor
final class CloudTerminalPaneResolution {
    private var result: Result<SurfaceProjection, Error>?
    private var waiters: [UUID: CheckedContinuation<SurfaceProjection, Error>] = [:]

    func value() async throws -> SurfaceProjection {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func complete(_ result: Result<SurfaceProjection, Error>) {
        self.result = result
        let waiting = waiters.values
        waiters.removeAll()
        for waiter in waiting { waiter.resume(with: result) }
    }

    func retry() { result = nil }

    deinit {
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
    }
}
