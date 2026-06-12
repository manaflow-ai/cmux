import Bonsplit
import CmuxFileWatch
import Combine
import CryptoKit
import Foundation


// MARK: - Config File Schema
extension CodingUserInfoKey {
    static let cmuxWorkspaceColorDefaults = CodingUserInfoKey(rawValue: "cmuxWorkspaceColorDefaults")!
}

struct CmuxConfigFile: Codable, Sendable {
    var actions: [String: CmuxConfigActionDefinition]
    var ui: CmuxConfigUIDefinition?
    var notifications: CmuxNotificationConfigDefinition?
    var newWorkspaceCommand: String?
    var surfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
    var commands: [CmuxCommandDefinition]
    var vault: CmuxVaultConfigDefinition?
    var workspaceGroups: CmuxConfigWorkspaceGroupsDefinition?

    private enum CodingKeys: String, CodingKey {
        case actions, ui, notifications, newWorkspaceCommand, surfaceTabBarButtons, commands, vault, workspaceGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedActions = try container.decodeIfPresent(
            [String: CmuxConfigActionDefinition].self,
            forKey: .actions
        ) ?? [:]
        actions = try Self.normalizedActions(
            decodedActions,
            codingPath: decoder.codingPath + [CodingKeys.actions]
        )
        ui = try container.decodeIfPresent(CmuxConfigUIDefinition.self, forKey: .ui)
        notifications = try container.decodeIfPresent(CmuxNotificationConfigDefinition.self, forKey: .notifications)

        if let rawNewWorkspaceCommand = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCommand) {
            let trimmed = rawNewWorkspaceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.newWorkspaceCommand],
                        debugDescription: "newWorkspaceCommand must not be blank"
                    )
                )
            }
            newWorkspaceCommand = trimmed
        } else {
            newWorkspaceCommand = nil
        }

        let rootSurfaceButtons = try container.decodeIfPresent(
            [CmuxSurfaceTabBarButton].self,
            forKey: .surfaceTabBarButtons
        )
        let configuredSurfaceButtons = ui?.surfaceTabBar?.buttons ?? rootSurfaceButtons
        if let configuredSurfaceButtons {
            surfaceTabBarButtons = try Self.validatedSurfaceTabBarButtons(
                configuredSurfaceButtons,
                codingPath: decoder.codingPath + [
                    ui?.surfaceTabBar?.buttons == nil ? CodingKeys.surfaceTabBarButtons : CodingKeys.ui
                ]
            )
        } else {
            surfaceTabBarButtons = nil
        }
        commands = try container.decodeIfPresent([CmuxCommandDefinition].self, forKey: .commands) ?? []
        vault = try container.decodeIfPresent(CmuxVaultConfigDefinition.self, forKey: .vault)
        workspaceGroups = try container.decodeIfPresent(
            CmuxConfigWorkspaceGroupsDefinition.self,
            forKey: .workspaceGroups
        )
    }

    private static func normalizedActions(
        _ decodedActions: [String: CmuxConfigActionDefinition],
        codingPath: [CodingKey]
    ) throws -> [String: CmuxConfigActionDefinition] {
        var actions: [String: CmuxConfigActionDefinition] = [:]
        var canonicalIDs: [String: String] = [:]
        for (rawID, action) in decodedActions {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions keys must not be blank"
                    )
                )
            }
            if actions[id] != nil {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate ids"
                    )
                )
            }
            let canonicalID = CmuxSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
            if let existingID = canonicalIDs[canonicalID] {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate aliases for '\(canonicalID)' (found '\(existingID)' and '\(id)')"
                    )
                )
            }
            canonicalIDs[canonicalID] = id
            actions[id] = action
        }
        return actions
    }

    private static func validatedSurfaceTabBarButtons(
        _ buttons: [CmuxSurfaceTabBarButton],
        codingPath: [CodingKey]
    ) throws -> [CmuxSurfaceTabBarButton] {
        var seen = Set<String>()
        for button in buttons {
            if !seen.insert(button.id).inserted {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "surface tab bar buttons must not contain duplicate ids"
                    )
                )
            }
        }
        return buttons
    }
}

/// Per-cwd customization for sidebar workspace groups. Keyed by the anchor
/// workspace's cwd. Keys containing `*` or `?` are matched as fnmatch globs;
/// otherwise they are path prefixes. Longest match wins. `~` is expanded.
struct CmuxConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    var byCwd: [String: CmuxConfigWorkspaceGroupEntry]?

    enum CodingKeys: String, CodingKey {
        case byCwd
    }
}

struct CmuxConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    var color: String?
    var icon: String?
    var contextMenu: [CmuxConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (`WorkspaceGroupNewWorkspacePlacementSettings.resolved()`).
    var newWorkspacePlacement: String?
}

/// Resolved snapshot of a per-cwd workspace group entry, with the JSON key
/// normalized for matching and any `contextMenu` actions resolved against the
/// loaded action/command tables.
struct CmuxResolvedWorkspaceGroupConfig: Sendable, Equatable {
    let originalKey: String
    let normalizedKey: String
    let isGlob: Bool
    let color: String?
    let iconSymbol: String?
    let contextMenuItems: [CmuxResolvedConfigContextMenuItem]
    /// Parsed override for where the `+` button places its new workspace.
    /// nil means "fall through to the global default."
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
}

struct CmuxConfigIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case newWorkspaceActionNotFound
        case newWorkspaceCommandNotFound
        case newWorkspaceCommandRequiresWorkspace
        case schemaError
    }

    let kind: Kind
    let settingName: String
    let commandName: String?
    let sourcePath: String?
    let message: String?

    init(
        kind: Kind,
        settingName: String,
        commandName: String? = nil,
        sourcePath: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.settingName = settingName
        self.commandName = commandName
        self.sourcePath = sourcePath
        self.message = message
    }

    var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    var logMessage: String {
        switch kind {
        case .newWorkspaceActionNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded action"
        case .newWorkspaceCommandNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded command"
        case .newWorkspaceCommandRequiresWorkspace:
            return "\(settingName) '\(commandName ?? "")' must reference a workspace command"
        case .schemaError:
            return "\(settingName) has a schema error: \(message ?? "unknown error")"
        }
    }
}

