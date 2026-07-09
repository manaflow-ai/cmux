import CmuxAgentChat
import Foundation

/// Immutable row data for one recently changed agent-owned file.
struct AgentRecentFile: Identifiable, Sendable, Equatable {
    let path: String
    let relativePath: String
    let agentKind: ChatAgentKind
    let operation: ChatFileEdit.Operation
    let modifiedAt: Date

    var id: String { path }

    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    var directoryPath: String {
        let directory = (relativePath as NSString).deletingLastPathComponent
        return directory == "." ? "" : directory
    }

    var symbolName: String {
        switch operation {
        case .edit:
            return "doc.text"
        case .write:
            return "doc.badge.plus"
        case .delete:
            return "doc.badge.minus"
        }
    }
}
