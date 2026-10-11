public import CmuxMobileShellModel
public import Foundation

/// Device-local, display-only workspace snapshots used to render the computer
/// list while a live Mac connection is being established. The snapshot never
/// grants authority for an action. A live workspace list replaces it before
/// mutations or terminal streaming are allowed.
@MainActor
public final class MobileWorkspaceSnapshotStore {
    private final class DefaultsBox: @unchecked Sendable {
        let value: UserDefaults

        init(_ value: UserDefaults) {
            self.value = value
        }
    }

    private actor Persistence {
        private let defaults: DefaultsBox
        private let maxAge: TimeInterval
        private let maxRecords: Int
        private let maxRecordBytes: Int
        private var knownKeys: Set<String>?
        private var savedAtByKey: [String: Date] = [:]
        private var latestRevisionByKey: [String: UInt64] = [:]
        // A forced removal advances this generation so an encode that started
        // before the removal cannot recreate the deleted row when it finishes.
        private var generationByKey: [String: UInt64] = [:]

        init(
            defaults: DefaultsBox,
            maxAge: TimeInterval,
            maxRecords: Int,
            maxRecordBytes: Int
        ) {
            self.defaults = defaults
            self.maxAge = maxAge
            self.maxRecords = maxRecords
            self.maxRecordBytes = maxRecordBytes
        }

        func loadAll(
            userID: String,
            teamID: String?,
            namespace: String
        ) -> [(MacPairingKey, MacWorkspaceState)] {
            let now = Date()
            var keys = knownKeys ?? Set(
                defaults.value.dictionaryRepresentation().keys.filter { $0.hasPrefix(namespace) }
            )
            var result: [(MacPairingKey, MacWorkspaceState)] = []
            var removedKeys = Set<String>()
            for key in keys {
                guard let storedScope = Self.scope(fromStorageKey: key, namespace: namespace),
                      storedScope.userID == userID,
                      storedScope.teamID == teamID else {
                    continue
                }
                guard let data = defaults.value.data(forKey: key),
                      let record = try? JSONDecoder().decode(Record.self, from: data),
                      (record.userID == nil || record.userID == userID),
                      (record.teamID == nil || record.teamID == teamID) else {
                    defaults.value.removeObject(forKey: key)
                    removedKeys.insert(key)
                    continue
                }
                guard now.timeIntervalSince(record.savedAt) <= maxAge else {
                    defaults.value.removeObject(forKey: key)
                    removedKeys.insert(key)
                    savedAtByKey[key] = nil
                    continue
                }
                let pairing = MacPairingKey(
                    macDeviceID: record.macDeviceID,
                    instanceTag: record.instanceTag
                )
                result.append((pairing, MacWorkspaceState(
                    macDeviceID: pairing.canonicalMacDeviceID,
                    instanceTag: pairing.normalizedInstanceTag,
                    displayName: record.displayName,
                    workspaces: record.workspaces.map { $0.value() },
                    groups: record.groups.map { $0.value() },
                    workspaceGroupsAreAuthoritative:
                        record.workspaceGroupsAreAuthoritative ?? !record.groups.isEmpty,
                    status: .reconnecting,
                    workspaceSnapshotIsAuthoritative: false,
                    actionCapabilities: .none
                )))
                savedAtByKey[key] = record.savedAt
            }
            keys.subtract(removedKeys)
            knownKeys = keys
            enforceLimit(keys: keys)
            return result
        }

        func save(
            request: SaveRequest,
            key: String,
            revision: UInt64,
            generation: UInt64,
            namespace: String
        ) {
            guard generation == (generationByKey[key] ?? 0) else { return }
            guard let data = MobileWorkspaceSnapshotStore.encode(request),
                  data.count <= maxRecordBytes else { return }
            if let latest = latestRevisionByKey[key], revision < latest { return }
            latestRevisionByKey[key] = revision
            defaults.value.set(data, forKey: key)
            var keys = knownKeys ?? Set(
                defaults.value.dictionaryRepresentation().keys.filter { $0.hasPrefix(namespace) }
            )
            keys.insert(key)
            knownKeys = keys
            savedAtByKey[key] = request.savedAt
            enforceLimit(keys: keys)
        }

        func remove(key: String, revision: UInt64, force: Bool) {
            if force {
                generationByKey[key] = (generationByKey[key] ?? 0) &+ 1
                latestRevisionByKey[key] = (latestRevisionByKey[key] ?? revision) &+ 1
            } else {
                if let latest = latestRevisionByKey[key], revision < latest { return }
                latestRevisionByKey[key] = revision
            }
            defaults.value.removeObject(forKey: key)
            knownKeys?.remove(key)
            savedAtByKey[key] = nil
        }

        private func enforceLimit(keys: Set<String>) {
            guard keys.count > maxRecords else { return }
            for key in keys where savedAtByKey[key] == nil {
                savedAtByKey[key] = Self.savedAt(
                    from: defaults.value.data(forKey: key)
                ) ?? .distantPast
            }
            let keep = Set(
                keys.sorted {
                    (savedAtByKey[$0] ?? .distantPast) > (savedAtByKey[$1] ?? .distantPast)
                }.prefix(maxRecords)
            )
            for key in keys where !keep.contains(key) {
                defaults.value.removeObject(forKey: key)
                savedAtByKey[key] = nil
                latestRevisionByKey[key] = nil
            }
            knownKeys = keep
        }

        private static func savedAt(from data: Data?) -> Date? {
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  let seconds = dictionary["savedAt"] as? NSNumber else { return nil }
            return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
        }

        private static func scope(
            fromStorageKey key: String,
            namespace: String
        ) -> (userID: String, teamID: String?)? {
            let encoded = String(key.dropFirst(namespace.count))
            var padded = encoded.replacingOccurrences(of: "_", with: "/")
                .replacingOccurrences(of: "-", with: "+")
            padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
            guard let data = Data(base64Encoded: padded),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            let parts = raw.split(separator: "\u{1F}", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            return (
                userID: String(parts[0]),
                teamID: parts[1].isEmpty ? nil : String(parts[1])
            )
        }
    }

    private struct Record: Codable, Sendable {
        let savedAt: Date
        // Scope fields are stored inside the value as well as in its key. This
        // lets startup enumerate only the current account/team's snapshots
        // before the paired-Mac SQLite read completes.
        let userID: String?
        let teamID: String?
        let macDeviceID: String
        let instanceTag: String?
        let displayName: String?
        let workspaces: [Workspace]
        let groups: [Group]
        // Optional keeps snapshots written by older builds readable. A nil
        // value falls back to the historical non-empty-groups inference.
        let workspaceGroupsAreAuthoritative: Bool?
    }

    private struct SaveRequest: Sendable {
        let state: MacWorkspaceState
        let userID: String
        let teamID: String?
        let pairing: MacPairingKey
        let savedAt: Date
    }

    private struct Workspace: Codable, Sendable {
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
            // Terminal output can contain commands, tokens, and other private
            // content. Snapshots are retained locally for several days, so
            // they carry workspace metadata only.
            previewText = nil
            previewAt = workspace.previewAt
            lastActivityAt = workspace.lastActivityAt
            hasUnread = workspace.hasUnread
            unreadCount = workspace.unreadCount
            terminals = workspace.terminals.map(Terminal.init)
        }

        func value() -> MobileWorkspacePreview {
            var preview = MobileWorkspacePreview(
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
                previewText: nil,
                previewAt: previewAt,
                lastActivityAt: lastActivityAt,
                hasUnread: hasUnread,
                unreadCount: unreadCount,
                terminals: terminals.map { $0.value() }
            )
            preview.remoteWorkspaceID = remoteWorkspaceID.map(MobileWorkspacePreview.ID.init(rawValue:))
            return preview
        }
    }

    private struct Terminal: Codable, Sendable {
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

    private struct Group: Codable, Sendable {
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
    private let maxRecords = 64
    private let maxRecordBytes = 512 * 1024
    // This is MainActor-owned so a save captures its generation before it
    // enters the persistence actor. A later forced removal advances the token
    // synchronously and invalidates that already-started save.
    private var generationByKey: [String: UInt64] = [:]
    private let persistence: Persistence

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistence = Persistence(
            defaults: DefaultsBox(defaults),
            maxAge: maxAge,
            maxRecords: maxRecords,
            maxRecordBytes: maxRecordBytes
        )
    }

    private nonisolated static func encode(_ request: SaveRequest) -> Data? {
        let state = request.state
        let record = Record(
            savedAt: request.savedAt,
            userID: request.userID,
            teamID: request.teamID,
            macDeviceID: request.pairing.canonicalMacDeviceID,
            instanceTag: request.pairing.normalizedInstanceTag,
            displayName: state.displayName,
            workspaces: state.workspaces.map(Workspace.init),
            groups: state.groups.map(Group.init),
            workspaceGroupsAreAuthoritative: state.workspaceGroupsAreAuthoritative
        )
        return try? JSONEncoder().encode(record)
    }

    public func load(
        userID: String,
        teamID: String?,
        pairing: MacPairingKey
    ) -> MacWorkspaceState? {
        let storageKey = key(userID: userID, teamID: teamID, pairing: pairing)
        guard let data = defaults.data(forKey: storageKey),
              let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return nil
        }
        guard Date().timeIntervalSince(record.savedAt) <= maxAge else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        guard
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
            workspaceGroupsAreAuthoritative: record.workspaceGroupsAreAuthoritative ?? !record.groups.isEmpty,
            status: .reconnecting,
            workspaceSnapshotIsAuthoritative: false,
            actionCapabilities: .none
        )
    }

    /// Loads all display-only snapshots for one account/team scope. This is
    /// intentionally independent of the paired-Mac store so the workspace list
    /// can render while that store is still being read. Older records without
    /// embedded scope fields remain supported because their storage key also
    /// encodes the account/team scope.
    public func loadAll(
        userID: String,
        teamID: String?
    ) async -> [(MacPairingKey, MacWorkspaceState)] {
        await persistence.loadAll(
            userID: userID,
            teamID: teamID,
            namespace: namespace
        )
    }

    public func save(
        state: MacWorkspaceState,
        userID: String,
        teamID: String?,
        pairing: MacPairingKey,
        revision: UInt64 = 0
    ) async {
        let storageKey = key(userID: userID, teamID: teamID, pairing: pairing)
        let generation = generationByKey[storageKey] ?? 0
        // An authoritative empty list is a deletion, not a reason to retain
        // the previous preview. Otherwise a closed workspace would reappear
        // on the next launch until the snapshot TTL expired.
        guard !state.workspaces.isEmpty else {
            await persistence.remove(
                key: storageKey,
                revision: revision,
                force: false
            )
            return
        }
        let savedAt = Date()
        let request = SaveRequest(
            state: state,
            userID: userID,
            teamID: teamID,
            pairing: pairing,
            savedAt: savedAt
        )
        guard !Task.isCancelled else { return }
        await persistence.save(
            request: request,
            key: storageKey,
            revision: revision,
            generation: generation,
            namespace: namespace
        )
    }

    public func remove(
        userID: String,
        teamID: String?,
        pairing: MacPairingKey,
        revision: UInt64 = 0,
        force: Bool = false
    ) async {
        let storageKey = key(userID: userID, teamID: teamID, pairing: pairing)
        if force {
            generationByKey[storageKey] = (generationByKey[storageKey] ?? 0) &+ 1
        }
        await persistence.remove(key: storageKey, revision: revision, force: force)
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
