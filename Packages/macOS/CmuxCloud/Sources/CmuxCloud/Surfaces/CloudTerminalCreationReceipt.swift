import CmuxSurfaceCatalogModel
import Foundation

/// The authoritative remote result of one reserved pane, shared with child creates.
/// Waiting for this receipt preserves parent geometry without serializing unrelated
/// terminals. A failed parent settles its children; explicit retry opens a new attempt.
@MainActor
public final class CloudTerminalCreationReceipt {
    public nonisolated init() {}

    private var result: Result<SurfaceResource, Error>?
    private var waiters: [UUID: CheckedContinuation<SurfaceResource, Error>] = [:]

    public func beginAttempt() {
        if case .failure = result { result = nil }
    }

    public func finish(_ result: Result<SurfaceResource, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    public func value() async throws -> SurfaceResource {
        try Task.checkCancellation()
        if let result { return try result.get() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}
