import Foundation

/// A `left_sidebar` socket command. The left sidebar has no modes, so it only
/// changes visibility, takes focus, or reports whether it is showing.
enum LeftSidebarRemoteCommand: Equatable, Sendable {
    case toggle
    case show
    case hide
    case focus
    case getState

    /// Only `focus` may move in-app focus; the visibility commands run from
    /// background scripts and agents and must leave focus where it is.
    var allowsInAppFocusMutations: Bool {
        self == .focus
    }
}

struct LeftSidebarRemoteRequest: Equatable, Sendable {
    let command: LeftSidebarRemoteCommand
    let target: SidebarRemoteTarget
}

struct LeftSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

enum LeftSidebarRemoteApplyResult: Equatable, Sendable {
    case ok
    case state(visible: Bool)
    case failure(String)
}

extension LeftSidebarRemoteRequest {
    private static var argumentsMessages: SidebarRemoteArgumentsMessages {
        SidebarRemoteArgumentsMessages(
            optionRequiresID: { option in
                String(localized: "leftSidebar.remote.error.optionRequiresID", defaultValue: "ERROR: \(option) requires an id")
            },
            unknownOption: { option in
                String(localized: "leftSidebar.remote.error.unknownOption", defaultValue: "ERROR: Unknown left sidebar option '\(option)'")
            },
            invalidTargetID: { name, value in
                String(localized: "leftSidebar.remote.error.invalidTargetID", defaultValue: "ERROR: Invalid left sidebar --\(name) id '\(value)'")
            }
        )
    }

    static func parse(tokens: [String]) -> Result<LeftSidebarRemoteRequest, LeftSidebarRemoteParseError> {
        let arguments: SidebarRemoteArguments
        switch SidebarRemoteArguments.parse(tokens: tokens, acceptsNoFocus: false, messages: argumentsMessages) {
        case .success(let value):
            arguments = value
        case .failure(let error):
            return .failure(.init(message: error.message))
        }
        let positional = arguments.positional

        guard let action = positional.first?.lowercased() else {
            return .failure(.init(message: String(localized: "leftSidebar.remote.error.usage", defaultValue: "ERROR: Usage: left_sidebar <toggle|show|hide|focus|mode> [--workspace=<workspace-id>] [--window=<window-id>]")))
        }

        let command: LeftSidebarRemoteCommand
        switch action {
        case "toggle": command = .toggle
        case "show": command = .show
        case "hide": command = .hide
        case "focus": command = .focus
        case "mode": command = .getState
        default:
            return .failure(.init(message: String(localized: "leftSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown left sidebar command '\(action)'")))
        }
        guard positional.count == 1 else {
            return .failure(.init(message: String(localized: "leftSidebar.remote.error.usage.command", defaultValue: "ERROR: Usage: left_sidebar \(action) [--workspace=<workspace-id>] [--window=<window-id>]")))
        }
        return .success(.init(command: command, target: arguments.target))
    }
}
