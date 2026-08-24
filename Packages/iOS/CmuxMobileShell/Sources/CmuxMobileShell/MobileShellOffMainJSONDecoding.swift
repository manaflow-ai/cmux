import Foundation

extension MobileShellComposite {
    /// Decodes one JSON payload on the global concurrent executor instead of
    /// the caller's actor.
    ///
    /// Workspace-list deltas, cursor-fetch snapshots, and the legacy full-list
    /// response all arrive on `@MainActor` paths that previously ran
    /// `JSONDecoder` inline, so every list emission taxed the same runloop
    /// that renders scrolling. Callers must re-validate their
    /// connection/authority guards after the suspension, exactly like any
    /// other await in those paths.
    nonisolated static func decodeOffMain<T: Decodable & Sendable>(
        _ type: T.Type,
        from data: Data
    ) async throws -> T {
        let decoderTask = Task.detached(priority: .userInitiated) {
            try JSONDecoder().decode(T.self, from: data)
        }
        return try await withTaskCancellationHandler(
            operation: { try await decoderTask.value },
            onCancel: { decoderTask.cancel() }
        )
    }

    /// Same executor contract for types with a bespoke `decode(_:)` (wire
    /// shapes with custom key mapping), used by the legacy full-list path.
    nonisolated static func decodeOffMain<T: Sendable>(
        _ data: Data,
        as decode: @escaping @Sendable (Data) throws -> T
    ) async throws -> T {
        let decoderTask = Task.detached(priority: .userInitiated) {
            try decode(data)
        }
        return try await withTaskCancellationHandler(
            operation: { try await decoderTask.value },
            onCancel: { decoderTask.cancel() }
        )
    }
}
