import CmuxSidebar
import Foundation

// `RightSidebarRemoteCommand`, `RightSidebarRemoteTarget`,
// `RightSidebarRemoteState`, and `RightSidebarRemoteApplyResult` now live in
// `CmuxSidebar` (Remote/) alongside the `apply` interpreter. This file keeps the
// app-side CLI token parser, which uses `String(localized:)` and so must stay
// in the app bundle.

nonisolated struct RightSidebarRemoteRequest: Equatable, Sendable {
    let command: RightSidebarRemoteCommand
    let target: RightSidebarRemoteTarget
}

nonisolated struct RightSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

extension RightSidebarRemoteRequest {
    static func parse(tokens: [String]) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        var positional: [String] = []
        var target = RightSidebarRemoteTarget()
        var noFocus = false
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token == "--no-focus" {
                noFocus = true
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
            guard positional.count == 2 else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.set", defaultValue: "ERROR: Usage: right_sidebar set <files|find|vault|sessions|feed|dock> [--no-focus] [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            let rawMode = positional[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if let mode = RightSidebarMode.from(cliArgument: rawMode), mode != .customSidebar {
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
            if let mode = RightSidebarMode.from(cliArgument: action), mode != .customSidebar {
                return .success(.init(command: .setMode(mode, focus: true), target: target))
            }
            return .failure(.init(message: String(localized: "rightSidebar.remote.error.unknownCommand", defaultValue: "ERROR: Unknown right sidebar command '\(action)'")))
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
