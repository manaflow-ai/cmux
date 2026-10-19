import AppKit
import Foundation

extension FileExplorerState {
    var rightSidebarRemoteModeRawValue: String {
        mode.rawValue
    }
}

enum RightSidebarRemoteCommand: Equatable, Sendable {
    case toggle
    case show
    case hide
    case focus
    case setMode(RightSidebarMode, focus: Bool)
    /// Switch to the Custom mode, optionally selecting which sidebar file
    /// (`right_sidebar set custom [name]`). A nil name keeps the persisted one.
    case setCustomSidebar(name: String?, focus: Bool)
    case getState
}

struct RightSidebarRemoteRequest: Equatable, Sendable {
    let command: RightSidebarRemoteCommand
    let target: SidebarRemoteTarget
}

struct RightSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

struct RightSidebarRemoteState: Equatable, Sendable {
    let visible: Bool
    let modeRawValue: String
}

enum RightSidebarRemoteApplyResult: Equatable, Sendable {
    case ok
    case state(RightSidebarRemoteState)
    case failure(String)
}

extension RightSidebarRemoteRequest {
    private static var argumentsMessages: SidebarRemoteArgumentsMessages {
        SidebarRemoteArgumentsMessages(
            optionRequiresID: { option in
                String(localized: "rightSidebar.remote.error.optionRequiresID", defaultValue: "ERROR: \(option) requires an id")
            },
            unknownOption: { option in
                String(localized: "rightSidebar.remote.error.unknownOption", defaultValue: "ERROR: Unknown right sidebar option '\(option)'")
            },
            invalidTargetID: { name, value in
                String(localized: "rightSidebar.remote.error.invalidTargetID", defaultValue: "ERROR: Invalid right sidebar --\(name) id '\(value)'")
            }
        )
    }

    static func parse(tokens: [String]) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        let arguments: SidebarRemoteArguments
        switch SidebarRemoteArguments.parse(tokens: tokens, acceptsNoFocus: true, messages: argumentsMessages) {
        case .success(let value):
            arguments = value
        case .failure(let error):
            return .failure(.init(message: error.message))
        }
        let positional = arguments.positional
        let target = arguments.target
        let noFocus = arguments.noFocus

        guard let action = positional.first?.lowercased() else {
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage", defaultValue: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode> [mode] [--workspace=<workspace-id>] [--window=<window-id>] [--no-focus]")))
        }

        switch action {
        case "toggle":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.toggle", defaultValue: "ERROR: Usage: right_sidebar toggle [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .toggle, target: target))
        case "show":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.show", defaultValue: "ERROR: Usage: right_sidebar show [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .show, target: target))
        case "hide":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.hide", defaultValue: "ERROR: Usage: right_sidebar hide [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .hide, target: target))
        case "focus":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.focus", defaultValue: "ERROR: Usage: right_sidebar focus [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .focus, target: target))
        case "mode", "state":
            guard positional.count == 1, !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.mode", defaultValue: "ERROR: Usage: right_sidebar mode [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .getState, target: target))
        case "set":
            guard positional.count == 2 || positional.count == 3 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.set", defaultValue: "ERROR: Usage: right_sidebar set <files|find|vault|sessions|feed|dock|cloud|devices|custom> [sidebar-name] [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let rawMode = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let mode = RightSidebarMode.from(cliArgument: rawMode) {
                if mode == .customSidebar {
                    let name = positional.count == 3
                        ? positional[2].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        : nil
                    return .success(.init(command: .setCustomSidebar(name: name, focus: !noFocus), target: target))
                }
                guard positional.count == 2 else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.set", defaultValue: "ERROR: Usage: right_sidebar set <files|find|vault|sessions|feed|dock|cloud|devices|custom> [sidebar-name] [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
                }
                return .success(.init(command: .setMode(mode, focus: !noFocus), target: target))
            }
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownMode", defaultValue: "ERROR: Unknown right sidebar mode '\(positional[1])'")))
        default:
            guard !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.noFocusOnlySet", defaultValue: "ERROR: --no-focus is only valid with right_sidebar set")))
            }
            guard positional.count == 1 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
            }
            if let mode = RightSidebarMode.from(cliArgument: action) {
                if mode == .customSidebar {
                    return .success(.init(command: .setCustomSidebar(name: nil, focus: true), target: target))
                }
                return .success(.init(command: .setMode(mode, focus: true), target: target))
            }
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
        }
    }
}
