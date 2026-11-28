#if canImport(UIKit)
import Foundation

/// Serializes the DEBUG preview's held refresh completions.
actor WorkspaceListPreviewRefreshGate {
    private var completions: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var releasePending = false

    func wait() async {
        let (stream, completion) = AsyncStream<Void>.makeStream()
        let refreshID = UUID()
        completions[refreshID] = completion
        if releasePending {
            releasePending = false
            completion.finish()
        }
        defer { completions.removeValue(forKey: refreshID) }
        for await _ in stream { break }
    }

    func finish() {
        guard !completions.isEmpty else {
            releasePending = true
            return
        }
        let currentCompletions = Array(completions.values)
        completions.removeAll()
        for completion in currentCompletions {
            completion.finish()
        }
    }
}
#endif
