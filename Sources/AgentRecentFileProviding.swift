import Foundation

/// Supplies recent transcript-derived file edits and invalidation events.
@MainActor
protocol AgentRecentFileProviding: AnyObject {
    func recentFiles(in scope: AgentRecentFileScope, limit: Int) async -> [AgentRecentFile]
    func changes() -> AsyncStream<Void>
}
