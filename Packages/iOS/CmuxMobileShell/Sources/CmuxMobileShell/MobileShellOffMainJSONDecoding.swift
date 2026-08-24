import Foundation

/// Decodes one JSON payload on the global concurrent executor instead of the
/// caller's actor.
///
/// Workspace-list deltas, cursor-fetch snapshots, and the legacy full-list
/// response all arrive on `@MainActor` paths that previously ran `JSONDecoder`
/// inline, so every list emission taxed the same runloop that renders
/// scrolling. Callers must re-validate their connection/authority guards after
/// the suspension, exactly like any other await in those paths.
func mobileShellDecodeOffMain<T: Decodable & Sendable>(
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
