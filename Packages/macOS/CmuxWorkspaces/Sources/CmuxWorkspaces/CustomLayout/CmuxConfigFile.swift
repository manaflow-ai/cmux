public import CMUXAgentLaunch
public import CmuxFoundation
import Foundation

/// The top-level `cmux.json` wire schema: the `Codable`, `Sendable` decode image
/// of a single config file (global or project-local).
///
/// Every field is the wire image of a config block whose value type lives in a
/// package this one can reach: `actions`/`ui`/`surfaceTabBarButtons`/`commands`/
/// `workspaceGroups` are the CmuxWorkspaces `CustomLayout/` schema, `vault` is
/// ``CmuxVaultConfigDefinition`` (CMUXAgentLaunch), and `notifications` is
/// ``CmuxNotificationConfigDefinition`` (CmuxFoundation). The app-side
/// `CmuxConfigStore` parses each file into this type and merges the layered
/// results; the app keeps a `typealias CmuxConfigFile = CmuxWorkspaces.CmuxConfigFile`
/// so the store's `parseConfig`/`loadAll` read it byte-identically.
///
/// ``init(from:)`` performs the schema validation that cannot be expressed as
/// plain field decoding: it normalizes the `actions` map (trimmed keys, no blank
/// ids, no duplicate ids or built-in aliases), rejects a blank
/// `newWorkspaceCommand`, prefers `ui.surfaceTabBar.buttons` over the top-level
/// `surfaceTabBarButtons` while rejecting duplicate button ids, and defaults the
/// absent map/array fields. Changing any token here is a wire-format change to
/// every user's `cmux.json`.
public struct CmuxConfigFile: Codable, Sendable {
    public var actions: [String: CmuxConfigActionDefinition]
    public var ui: CmuxConfigUIDefinition?
    public var notifications: CmuxNotificationConfigDefinition?
    public var newWorkspaceCommand: String?
    public var surfaceTabBarButtons: [CmuxSurfaceTabBarButton]?
    public var commands: [CmuxCommandDefinition]
    public var vault: CmuxVaultConfigDefinition?
    public var workspaceGroups: CmuxConfigWorkspaceGroupsDefinition?

    private enum CodingKeys: String, CodingKey {
        case actions, ui, notifications, newWorkspaceCommand, surfaceTabBarButtons, commands, vault, workspaceGroups
    }

    public init(
        actions: [String: CmuxConfigActionDefinition] = [:],
        ui: CmuxConfigUIDefinition? = nil,
        notifications: CmuxNotificationConfigDefinition? = nil,
        newWorkspaceCommand: String? = nil,
        surfaceTabBarButtons: [CmuxSurfaceTabBarButton]? = nil,
        commands: [CmuxCommandDefinition] = [],
        vault: CmuxVaultConfigDefinition? = nil,
        workspaceGroups: CmuxConfigWorkspaceGroupsDefinition? = nil
    ) {
        self.actions = actions
        self.ui = ui
        self.notifications = notifications
        self.newWorkspaceCommand = newWorkspaceCommand
        self.surfaceTabBarButtons = surfaceTabBarButtons
        self.commands = commands
        self.vault = vault
        self.workspaceGroups = workspaceGroups
    }

    public init(from decoder: any Decoder) throws {
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
        codingPath: [any CodingKey]
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
        codingPath: [any CodingKey]
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
