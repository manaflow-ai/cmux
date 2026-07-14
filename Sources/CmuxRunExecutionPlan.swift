import Foundation

struct CmuxRunExecutionPlan: Equatable {
    enum Target: Equatable {
        case workspace(windowId: UUID, tabManagerIdentity: ObjectIdentifier)
        case surface(
            windowId: UUID,
            workspaceId: UUID,
            paneId: UUID,
            anchorPanelId: UUID?
        )
        case pane(
            windowId: UUID,
            workspaceId: UUID,
            paneId: UUID,
            sourcePanelId: UUID,
            direction: CmuxRunURLRequest.Direction
        )
    }

    let command: String
    let workingDirectory: String
    let target: Target
    let placementDescription: String
    let targetDescription: String

    var launchCommand: String {
        CmuxRunShellCommandBuilder.launchCommand(for: command)
    }
}

enum CmuxRunShellCommandBuilder {
    static func launchCommand(for command: String) -> String {
        "/bin/zsh -lc \(shellQuote(command))"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

enum CmuxRunURLExecutionError: Error, Equatable {
    case busy
    case workingDirectoryContainsSurroundingWhitespace
    case workingDirectoryMustBeAbsolute
    case workingDirectoryNotFound
    case targetNotFound
    case remoteWorkspaceUnsupported
    case emptyPane
    case targetChanged
    case creationFailed
}
