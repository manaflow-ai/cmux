#if canImport(UIKit) && DEBUG
import Foundation

/// Serializes the DEBUG preview's held refresh completions.
actor WorkspaceListPreviewRefreshGate {
    private var completions: [UUID: AsyncStream<Void>.Continuation] = [:]

    func wait() async {
        let (stream, completion) = AsyncStream<Void>.makeStream()
        let refreshID = UUID()
        completions[refreshID] = completion
        defer { completions.removeValue(forKey: refreshID) }
        for await _ in stream { break }
    }

    func finish() {
        let currentCompletions = Array(completions.values)
        completions.removeAll()
        for completion in currentCompletions {
            completion.finish()
        }
    }
}
#endif
