import Foundation

/// Workspace identity and root used to select and relativize agent file edits.
struct AgentRecentFileScope: Hashable, Sendable {
    let workspaceID: String?
    let rootDirectory: String?

    init(workspaceID: UUID?, rootDirectory: String?) {
        self.workspaceID = workspaceID?.uuidString
        let root = rootDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootDirectory = root?.isEmpty == false ? root : nil
    }
}
