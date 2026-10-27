import CmuxNextAgentPane
import CmuxNextCompat
import Foundation

nonisolated enum FileTreeStrings {
    static var title: String { String(localized: "fileTree.title", defaultValue: "Files", table: "Handlers", bundle: .module) }
    static var noFolder: String {
        String(localized: "fileTree.noFolder", defaultValue: "This tab has no folder. Open Files from the chat's header again.",
               table: "Handlers", bundle: .module)
    }
    static var notRepository: String {
        String(localized: "fileTree.notRepository", defaultValue: "Files shows folders in a git repository. This folder is not in one.",
               table: "Handlers", bundle: .module)
    }
    static var unavailable: String {
        String(localized: "fileTree.unavailable",
               defaultValue: "The files could not be listed. Choose Refresh from the right-click menu to try again.",
               table: "Handlers", bundle: .module)
    }

    /// The page's message for a failed listing: not a repository, else ``unavailable``.
    static func message(for failure: AgentPaneGitFailure) -> String {
        let details = failure.details.flatMap { try? JSONSerialization.blockingJSONObject(with: $0) as? [String: Any] }
        let code = (details?["extra"] as? [String: Any])?["code"] as? String ?? details?["code"] as? String
        return code == "not_a_repository" ? notRepository : unavailable
    }
}
