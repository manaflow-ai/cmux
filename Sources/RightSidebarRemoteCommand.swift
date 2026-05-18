import Foundation

nonisolated struct RightSidebarRemoteTarget: Equatable, Sendable {
    var windowId: UUID? = nil
    var workspaceId: UUID? = nil

    var isActiveTarget: Bool {
        windowId == nil && workspaceId == nil
    }
}

nonisolated enum RightSidebarRemoteCommand: Equatable, Sendable {
    case toggle
    case show
    case hide
    case focus
    case setMode(RightSidebarMode, focus: Bool)
    case getState
}

nonisolated struct RightSidebarRemoteRequest: Equatable, Sendable {
    let command: RightSidebarRemoteCommand
    let target: RightSidebarRemoteTarget
}

nonisolated struct RightSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

nonisolated struct RightSidebarRemoteState: Equatable, Sendable {
    let visible: Bool
    let mode: RightSidebarMode
}

nonisolated enum RightSidebarRemoteApplyResult: Equatable, Sendable {
    case ok
    case state(RightSidebarRemoteState)
    case failure(String)
}

extension RightSidebarRemoteRequest {
    static func parse(tokens: [String]) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        var positional: [String] = []
        var target = RightSidebarRemoteTarget()
        var focusOverride: Bool?
        var sawFocus = false
        var sawNoFocus = false
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token == "--no-focus" {
                guard !sawFocus else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.focusConflict", defaultValue: "ERROR: --focus and --no-focus cannot be used together")))
                }
                sawNoFocus = true
                focusOverride = false
                index += 1
                continue
            }
            if token == "--focus" {
                guard !sawNoFocus else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.focusConflict", defaultValue: "ERROR: --focus and --no-focus cannot be used together")))
                }
                sawFocus = true
                if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    let next = tokens[index + 1]
                    if let parsed = parseFocusValue(next) {
                        focusOverride = parsed
                        index += 2
                    } else if Self.isKnownPositionalToken(next) {
                        focusOverride = true
                        index += 1
                    } else {
                        return .failure(.init(message: String(localized: "rightSidebar.remote.error.focusValue", defaultValue: "ERROR: --focus must be true or false")))
                    }
                } else {
                    focusOverride = true
                    index += 1
                }
                continue
            }
            if token.hasPrefix("--focus=") {
                guard !sawNoFocus else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.focusConflict", defaultValue: "ERROR: --focus and --no-focus cannot be used together")))
                }
                sawFocus = true
                let value = String(token.dropFirst("--focus=".count))
                guard let parsed = parseFocusValue(value) else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.focusValue", defaultValue: "ERROR: --focus must be true or false")))
                }
                focusOverride = parsed
                index += 1
                continue
            }
            if token == "--workspace" || token == "--tab" || token == "--window" {
                guard index + 1 < tokens.count else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.optionRequiresID", defaultValue: "ERROR: \(token) requires an id")))
                }
                let value = tokens[index + 1]
                if let error = parseTargetOption(name: String(token.dropFirst(2)), value: value, target: &target) {
                    return .failure(error)
                }
                index += 2
                continue
            }
            if token.hasPrefix("--workspace=") {
                let value = String(token.dropFirst("--workspace=".count))
                if let error = parseTargetOption(name: "workspace", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--tab=") {
                let value = String(token.dropFirst("--tab=".count))
                if let error = parseTargetOption(name: "tab", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--window=") {
                let value = String(token.dropFirst("--window=".count))
                if let error = parseTargetOption(name: "window", value: value, target: &target) {
                    return .failure(error)
                }
                index += 1
                continue
            }
            if token.hasPrefix("--") {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownOption", defaultValue: "ERROR: Unknown right sidebar option '\(token)'")))
            }
            positional.append(token)
            index += 1
        }

        guard let action = positional.first?.lowercased() else {
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage", defaultValue: "ERROR: Usage: right_sidebar <toggle|show|hide|focus|set|mode> [mode] [--workspace=<workspace-id>] [--window=<window-id>] [--focus[=true|false]] [--no-focus]")))
        }

        switch action {
        case "toggle":
            guard positional.count == 1, focusOverride == nil else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.toggle", defaultValue: "ERROR: Usage: right_sidebar toggle [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .toggle, target: target))
        case "show":
            guard positional.count == 1, focusOverride == nil else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.show", defaultValue: "ERROR: Usage: right_sidebar show [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .show, target: target))
        case "hide":
            guard positional.count == 1, focusOverride == nil else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.hide", defaultValue: "ERROR: Usage: right_sidebar hide [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .hide, target: target))
        case "focus":
            guard positional.count == 1, focusOverride == nil else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.focus", defaultValue: "ERROR: Usage: right_sidebar focus [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .focus, target: target))
        case "mode", "state":
            guard positional.count == 1, focusOverride == nil else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.mode", defaultValue: "ERROR: Usage: right_sidebar mode [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .getState, target: target))
        case "set":
            guard positional.count == 2 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.set", defaultValue: "ERROR: Usage: right_sidebar set <files|find|vault|sessions|feed|dock> [--focus[=true|false]] [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            guard let mode = RightSidebarMode.from(cliArgument: positional[1]) else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownMode", defaultValue: "ERROR: Unknown right sidebar mode '\(positional[1])'")))
            }
            return .success(.init(command: .setMode(mode, focus: focusOverride ?? false), target: target))
        default:
            guard positional.count == 1, let mode = RightSidebarMode.from(cliArgument: action) else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
            }
            return .success(.init(command: .setMode(mode, focus: focusOverride ?? false), target: target))
        }
    }

    private static func parseFocusValue(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "y", "on":
            return true
        case "false", "0", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func isKnownPositionalToken(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "toggle", "show", "hide", "focus", "set", "mode", "state", "files", "find", "vault", "sessions", "feed", "dock":
            return true
        default:
            return false
        }
    }

    private static func parseTargetOption(
        name: String,
        value: String,
        target: inout RightSidebarRemoteTarget
    ) -> RightSidebarRemoteParseError? {
        guard let uuid = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .init(message: String(localized: "rightSidebar.remote.error.invalidTargetID", defaultValue: "ERROR: Invalid right sidebar --\(name) id '\(value)'"))
        }
        switch name {
        case "window":
            target.windowId = uuid
        case "workspace", "tab":
            target.workspaceId = uuid
        default:
            return .init(message: String(localized: "rightSidebar.remote.error.unknownTargetOption", defaultValue: "ERROR: Unknown right sidebar target option '\(name)'"))
        }
        return nil
    }
}
