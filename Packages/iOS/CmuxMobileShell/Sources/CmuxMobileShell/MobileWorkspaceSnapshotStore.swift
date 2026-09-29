public import CmuxMobileShellModel
public import Foundation

/// Device-local, display-only workspace snapshots used to render the computer
/// list while a live Mac connection is being established. The snapshot never
/// grants authority for an action. A live workspace list replaces it before
/// mutations or terminal streaming are allowed.
@MainActor
public final class MobileWorkspaceSnapshotStore {
    private struct Record: Codable {
        let savedAt: Date
        let macDeviceID: String
        let instanceTag: String?
        let displayName: String?
        let workspaces: [Workspace]
        let groups: [Group]
    }

    private struct Workspace: Codable {
        let id: String
        let remoteWorkspaceID: String?
        let macDeviceID: String?
        let macDisplayName: String?
        let windowID: String?
        let name: String
        let customDescription: String?
        let customDescriptionIsTruncated: Bool
        let customColorHex: String?
        let currentDirectory: String?
        let isPinned: Bool
        let groupID: String?
        let previewText: String?
        let previewAt: Date?
        let lastActivityAt: Date?
        let hasUnread: Bool
        let unreadCount: Int?
        let terminals: [Terminal]

        init(_ workspace: MobileWorkspacePreview) {
            id = workspace.id.rawValue
            remoteWorkspaceID = workspace.remoteWorkspaceID?.rawValue
            macDeviceID = workspace.macDeviceID
            macDisplayName = workspace.macDisplayName
            windowID = workspace.windowID
            name = workspace.name
            customDescription = workspace.customDescription
            customDescriptionIsTruncated = workspace.customDescriptionIsTruncated
            customColorHex = workspace.customColorHex
            currentDirectory = workspace.currentDirectory
            isPinned = workspace.isPinned
            groupID = workspace.groupID?.rawValue
            previewText = workspace.previewText
            previewAt = workspace.previewAt
            lastActivityAt = workspace.lastActivityAt
            hasUnread = workspace.hasUnread
            unreadCount = workspace.unreadCount
            terminals = workspace.terminals.map(Terminal.init)
        }

        func value() -> MobileWorkspacePreview {
            MobileWorkspacePreview(
                id: .init(rawValue: id),
                macDeviceID: macDeviceID,
                macDisplayName: macDisplayName,
                windowID: windowID,
                name: name,
                customDescription: customDescription,
                customDescriptionIsTruncated: customDescriptionIsTruncated,
                customColorHex: customColorHex,
                currentDirectory: currentDirectory,
                isPinned: isPinned,
                groupID: groupID.map(MobileWorkspaceGroupPreview.ID.init(rawValue:)),
                previewText: previewText,
                previewAt: previewAt,
                lastActivityAt: lastActivityAt,
                hasUnread: hasUnread,
                unreadCount: unreadCount,
                terminals: terminals.map { $0.value() }
            )
        }
    }

    private struct Terminal: Codable {
        let id: String
        let name: String
        let currentDirectory: String?
        let isReady: Bool
        let isFocused: Bool

        init(_ terminal: MobileTerminalPreview) {
            id = terminal.id.rawValue
            name = terminal.name
            currentDirectory = terminal.currentDirectory
            isReady = terminal.isReady
            isFocused = terminal.isFocused
        }

        func value() -> MobileTerminalPreview {
            MobileTerminalPreview(
                id: .init(rawValue: id),
                name: name,
                currentDirectory: currentDirectory,
                isReady: isReady,
                isFocused: isFocused
            )
        }
    }

    private struct Group: Codable {
        let id: String
        let remoteGroupID: String?
        let macDeviceID: String?
        let macInstanceTag: String?
        let name: String
        let isCollapsed: Bool
        let isPinned: Bool
        let iconSymbol: String?
        let anchorWorkspaceID: String
        let isEmpty: Bool

        init(_ group: MobileWorkspaceGroupPreview) {
            id = group.id.rawValue
            remoteGroupID = group.remoteGroupID?.rawValue
            macDeviceID = group.macDeviceID
            macInstanceTag = group.macInstanceTag
            name = group.name
            isCollapsed = group.isCollapsed
            isPinned = group.isPinned
            iconSymbol = group.iconSymbol
            anchorWorkspaceID = group.anchorWorkspaceID.rawValue
            isEmpty = group.isEmpty
        }

        func value() -> MobileWorkspaceGroupPreview {
            MobileWorkspaceGroupPreview(
                id: .init(rawValue: id),
                remoteGroupID: remoteGroupID.map(MobileWorkspaceGroupPreview.ID.init(rawValue:)),
                macDeviceID: macDeviceID,
                macInstanceTag: macInstanceTag,
                name: name,
                isCollapsed: isCollapsed,
                isPinned: isPinned,
                iconSymbol: iconSymbol,
                anchorWorkspaceID: .init(rawValue: anchorWorkspaceID),
                isEmpty: isEmpty,
                actionCapabilities: nil
            )
        }
    }

    private let defaults: UserDefaults
    private let namespace = "cmux.mobile.v2.workspace-snapshot."
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(
        userID: String,
        teamID: String?,
        pairing: MacPairingKey
    ) -> MacWorkspaceState? {
        guard let data = defaults.data(forKey: key(userID: userID, teamID: teamID, pairing: pairing)),
              let record = try? JSONDecoder().decode(Record.self, from: data),
              Date().timeIntervalSince(record.savedAt) <= maxAge,
              record.macDeviceID == pairing.canonicalMacDeviceID,
              MacPairingKey(macDeviceID: record.macDeviceID, instanceTag: record.instanceTag)
                  == pairing else {
            return nil
        }
        return MacWorkspaceState(
            macDeviceID: pairing.canonicalMacDeviceID,
            instanceTag: pairing.normalizedInstanceTag,
            displayName: record.displayName,
            workspaces: record.workspaces.map { $0.value() },
            groups: record.groups.map { $0.value() },
            workspaceGroupsAreAuthoritative: !record.groups.isEmpty,
            status: .reconnecting,
            workspaceSnapshotIsAuthoritative: false,
            actionCapabilities: .none
        )
    }

    public func save(
        state: MacWorkspaceState,
        userID: String,
        teamID: String?,
        pairing: MacPairingKey
    ) {
        guard !state.workspaces.isEmpty else { return }
        let record = Record(
            savedAt: Date(),
            macDeviceID: pairing.canonicalMacDeviceID,
            instanceTag: pairing.normalizedInstanceTag,
            displayName: state.displayName,
            workspaces: state.workspaces.map(Workspace.init),
            groups: state.groups.map(Group.init)
        )
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key(userID: userID, teamID: teamID, pairing: pairing))
    }

    private func key(
        userID: String,
        teamID: String?,
        pairing: MacPairingKey
    ) -> String {
        let raw = [userID, teamID ?? "", pairing.pairingID].joined(separator: "\u{1F}")
        return namespace + Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
