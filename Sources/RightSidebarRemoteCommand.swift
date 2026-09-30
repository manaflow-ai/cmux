import AppKit
import CmuxFileSearch
import Foundation

struct RightSidebarRemoteTarget: Equatable, Sendable {
    var windowId: UUID? = nil
    var workspaceId: UUID? = nil

    var isActiveTarget: Bool {
        windowId == nil && workspaceId == nil
    }
}

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
    /// Switch to Find and search for `query` through the same path as typing
    /// in the Find field (`right_sidebar set find --query <text>`).
    case setFindQuery(FileSearchQuery, focus: Bool)
    case getState
    /// The Find query, phase and totals (`right_sidebar find_status`).
    case getFindStatus
}

struct RightSidebarRemoteRequest: Equatable, Sendable {
    let command: RightSidebarRemoteCommand
    let target: RightSidebarRemoteTarget
}

struct RightSidebarRemoteParseError: Error, Equatable, Sendable {
    let message: String
}

struct RightSidebarRemoteState: Equatable, Sendable {
    let visible: Bool
    let modeRawValue: String
}

/// What `right_sidebar find_status` reports so a script can assert results.
struct RightSidebarFindStatus: Equatable, Sendable {
    let query: FileSearchQuery
    /// `idle`, `searching`, `completed`, `limited` or `failed`.
    let phase: String
    let results: Int
    let files: Int
    /// The status line as shown, or nil when hidden.
    let message: String?
}

enum RightSidebarRemoteApplyResult: Equatable, Sendable {
    case ok
    case state(RightSidebarRemoteState)
    case findStatus(RightSidebarFindStatus)
    case failure(String)
}

extension RightSidebarRemoteRequest {
    static func parse(tokens: [String]) -> Result<RightSidebarRemoteRequest, RightSidebarRemoteParseError> {
        var positional: [String] = []
        var target = RightSidebarRemoteTarget()
        var noFocus = false
        var findPattern: String?
        var findFlags = (regex: false, caseSensitive: false, wholeWord: false)
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            if token == "--no-focus" {
                noFocus = true
                index += 1
                continue
            }
            if token == "--query" {
                guard index + 1 < tokens.count else {
                    return .failure(.init(message: String(localized: "rightSidebar.remote.error.queryRequiresValue", defaultValue: "ERROR: --query requires text")))
                }
                findPattern = tokens[index + 1]
                index += 2
                continue
            }
            if token.hasPrefix("--query=") {
                findPattern = String(token.dropFirst("--query=".count))
                index += 1
                continue
            }
            if token == "--regex" || token == "--case-sensitive" || token == "--whole-word" {
                switch token {
                case "--regex": findFlags.regex = true
                case "--case-sensitive": findFlags.caseSensitive = true
                default: findFlags.wholeWord = true
                }
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

        let hasFindOptions = findPattern != nil || findFlags.regex || findFlags.caseSensitive || findFlags.wholeWord
        if action == "find_status" || action == "find-status" {
            guard positional.count == 1, !noFocus, !hasFindOptions else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.findStatus", defaultValue: "ERROR: Usage: right_sidebar find_status [--workspace=<workspace-id>] [--window=<window-id>]")))
            }
            return .success(.init(command: .getFindStatus, target: target))
        }
        if hasFindOptions {
            let targetsFind = (action == "set" && positional.count == 2 && RightSidebarMode.from(cliArgument: positional[1]) == .find)
                || (positional.count == 1 && RightSidebarMode.from(cliArgument: action) == .find)
            guard targetsFind, let findPattern else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.usage.findQuery", defaultValue: "ERROR: Usage: right_sidebar set find --query <text> [--regex] [--case-sensitive] [--whole-word] [--no-focus]")))
            }
            guard action == "set" || !noFocus else {
                return .failure(.init(message: String(localized: "rightSidebar.remote.error.noFocusOnlySet", defaultValue: "ERROR: --no-focus is only valid with right_sidebar set")))
            }
            let query = FileSearchQuery(
                pattern: findPattern,
                isCaseSensitive: findFlags.caseSensitive,
                matchesWholeWord: findFlags.wholeWord,
                isRegex: findFlags.regex
            )
            return .success(.init(command: .setFindQuery(query, focus: !noFocus), target: target))
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
