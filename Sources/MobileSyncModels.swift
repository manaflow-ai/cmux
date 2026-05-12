import Darwin
import Foundation

nonisolated struct MobileWorkspaceID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        rawValue = uuid
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid workspace UUID: \(raw)"
            )
        }
        rawValue = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuidString)
    }
}

nonisolated struct MobileTerminalID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        rawValue = uuid
    }

    var uuidString: String { rawValue.uuidString }
    var description: String { uuidString }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid terminal UUID: \(raw)"
            )
        }
        rawValue = uuid
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuidString)
    }
}

nonisolated struct MobileDeviceID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct MobileClientID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct MobileAttachmentID: Hashable, Sendable, Codable, CustomStringConvertible {
    let rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated struct TerminalGridSize: Equatable, Sendable, Codable {
    let columns: Int
    let rows: Int

    init(columns: Int, rows: Int) {
        precondition(columns > 0, "TerminalGridSize columns must be positive")
        precondition(rows > 0, "TerminalGridSize rows must be positive")
        self.columns = columns
        self.rows = rows
    }

    init?(validatingColumns columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return nil }
        self.columns = columns
        self.rows = rows
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode(Int.self, forKey: .columns)
        let rows = try container.decode(Int.self, forKey: .rows)
        guard columns > 0, rows > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: columns <= 0 ? .columns : .rows,
                in: container,
                debugDescription: "Terminal grid dimensions must be positive"
            )
        }
        self.columns = columns
        self.rows = rows
    }
}

nonisolated enum TerminalAttachmentSurfaceKind: String, Sendable, Codable {
    case mac
    case iPhone
    case iPad
    case simulator
    case unknown
}

nonisolated struct TerminalAttachment: Equatable, Sendable, Codable, Identifiable {
    let id: MobileAttachmentID
    let clientID: MobileClientID
    let deviceID: MobileDeviceID
    let workspaceID: MobileWorkspaceID
    let terminalID: MobileTerminalID
    let surfaceKind: TerminalAttachmentSurfaceKind
    var deviceName: String?
    var gridSize: TerminalGridSize
    var isActive: Bool
    var lastHeartbeatAt: Date

    init(
        id: MobileAttachmentID,
        clientID: MobileClientID,
        deviceID: MobileDeviceID,
        workspaceID: MobileWorkspaceID,
        terminalID: MobileTerminalID,
        surfaceKind: TerminalAttachmentSurfaceKind,
        deviceName: String? = nil,
        gridSize: TerminalGridSize,
        isActive: Bool = true,
        lastHeartbeatAt: Date = Date()
    ) {
        self.id = id
        self.clientID = clientID
        self.deviceID = deviceID
        self.workspaceID = workspaceID
        self.terminalID = terminalID
        self.surfaceKind = surfaceKind
        self.deviceName = deviceName
        self.gridSize = gridSize
        self.isActive = isActive
        self.lastHeartbeatAt = lastHeartbeatAt
    }
}

nonisolated struct TerminalSizeDecision: Equatable, Sendable {
    let effectiveSize: TerminalGridSize
    let fallbackSize: TerminalGridSize
    let columnSourceAttachmentID: MobileAttachmentID?
    let rowSourceAttachmentID: MobileAttachmentID?
    let activeAttachmentCount: Int

    var isRemotelyConstrained: Bool {
        columnSourceAttachmentID != nil || rowSourceAttachmentID != nil
    }
}

nonisolated enum TerminalSizeCoordinator {
    static func decision(
        fallbackSize: TerminalGridSize,
        attachments: [TerminalAttachment]
    ) -> TerminalSizeDecision {
        let activeAttachments = attachments.filter(\.isActive)
        var columns = fallbackSize.columns
        var rows = fallbackSize.rows
        var columnSourceAttachmentID: MobileAttachmentID?
        var rowSourceAttachmentID: MobileAttachmentID?

        for attachment in activeAttachments {
            if attachment.gridSize.columns < columns {
                columns = attachment.gridSize.columns
                columnSourceAttachmentID = attachment.id
            }
            if attachment.gridSize.rows < rows {
                rows = attachment.gridSize.rows
                rowSourceAttachmentID = attachment.id
            }
        }

        return TerminalSizeDecision(
            effectiveSize: TerminalGridSize(columns: columns, rows: rows),
            fallbackSize: fallbackSize,
            columnSourceAttachmentID: columnSourceAttachmentID,
            rowSourceAttachmentID: rowSourceAttachmentID,
            activeAttachmentCount: activeAttachments.count
        )
    }
}

actor MobileTerminalAttachmentStore {
    private var attachmentsByID: [MobileAttachmentID: TerminalAttachment] = [:]

    func upsert(_ attachment: TerminalAttachment) {
        attachmentsByID[attachment.id] = attachment
    }

    func remove(_ attachmentID: MobileAttachmentID) {
        attachmentsByID.removeValue(forKey: attachmentID)
    }

    func removeAll(for terminalID: MobileTerminalID) {
        attachmentsByID = attachmentsByID.filter { _, attachment in
            attachment.terminalID != terminalID
        }
    }

    func attachments(for terminalID: MobileTerminalID) -> [TerminalAttachment] {
        attachmentsByID.values
            .filter { $0.terminalID == terminalID }
            .sorted { $0.id.rawValue < $1.id.rawValue }
    }

    func activeAttachmentCount() -> Int {
        attachmentsByID.values.filter(\.isActive).count
    }

    func decision(
        for terminalID: MobileTerminalID,
        fallbackSize: TerminalGridSize
    ) -> TerminalSizeDecision {
        TerminalSizeCoordinator.decision(
            fallbackSize: fallbackSize,
            attachments: attachments(for: terminalID)
        )
    }
}

nonisolated struct MobileTerminalSnapshot: Equatable, Sendable, Codable, Identifiable {
    let id: MobileTerminalID
    let workspaceID: MobileWorkspaceID
    let title: String
    let currentDirectory: String?
    let isFocused: Bool
    let displayOrder: Int
}

nonisolated struct MobileWorkspaceSnapshot: Equatable, Sendable, Codable, Identifiable {
    let id: MobileWorkspaceID
    let title: String
    let customTitle: String?
    let description: String?
    let currentDirectory: String?
    let isSelected: Bool
    let isPinned: Bool
    let customColor: String?
    let terminals: [MobileTerminalSnapshot]
}

extension MobileTerminalSnapshot {
    @MainActor
    init?(
        workspaceID: MobileWorkspaceID,
        panel: any Panel,
        focusedPanelID: UUID?,
        displayOrder: Int
    ) {
        guard let terminalPanel = panel as? TerminalPanel else { return nil }
        let directory = Self.normalizedDirectory(
            terminalPanel.directory.isEmpty ? terminalPanel.requestedWorkingDirectory : terminalPanel.directory
        )
        self.init(
            id: MobileTerminalID(terminalPanel.id),
            workspaceID: workspaceID,
            title: terminalPanel.displayTitle,
            currentDirectory: directory,
            isFocused: terminalPanel.id == focusedPanelID,
            displayOrder: displayOrder
        )
    }

    private nonisolated static func normalizedDirectory(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension MobileWorkspaceSnapshot {
    @MainActor
    init(workspace: Workspace, isSelected: Bool) {
        let workspaceID = MobileWorkspaceID(workspace.id)
        let orderedPanelIDs = Self.orderedPanelIDs(for: workspace)
        let terminals = orderedPanelIDs.enumerated().compactMap { displayOrder, panelID in
            workspace.panels[panelID].flatMap { panel in
                MobileTerminalSnapshot(
                    workspaceID: workspaceID,
                    panel: panel,
                    focusedPanelID: workspace.focusedPanelId,
                    displayOrder: displayOrder
                )
            }
        }

        self.init(
            id: workspaceID,
            title: workspace.customTitle ?? workspace.title,
            customTitle: workspace.customTitle,
            description: workspace.customDescription,
            currentDirectory: Self.normalizedText(workspace.currentDirectory),
            isSelected: isSelected,
            isPinned: workspace.isPinned,
            customColor: workspace.customColor,
            terminals: terminals
        )
    }

    @MainActor
    static func snapshots(from tabManager: TabManager) -> [MobileWorkspaceSnapshot] {
        tabManager.tabs.map { workspace in
            MobileWorkspaceSnapshot(
                workspace: workspace,
                isSelected: workspace.id == tabManager.selectedTabId
            )
        }
    }

    @MainActor
    private static func orderedPanelIDs(for workspace: Workspace) -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        for panelID in workspace.sidebarOrderedPanelIds() where seen.insert(panelID).inserted {
            ordered.append(panelID)
        }
        for panelID in workspace.panels.keys.sorted(by: { $0.uuidString < $1.uuidString })
            where seen.insert(panelID).inserted {
            ordered.append(panelID)
        }
        return ordered
    }

    private nonisolated static func normalizedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated enum MobileSyncListenerState: String, Sendable, Codable {
    case stopped
    case waitingForTailscale = "waiting_for_tailscale"
    case listening
}

nonisolated enum MobileSyncInterfaceAddressKind: String, Sendable, Codable {
    case ipv4
    case ipv6
}

nonisolated struct MobileSyncInterfaceAddress: Equatable, Sendable, Codable {
    let interfaceName: String
    let address: String
    let kind: MobileSyncInterfaceAddressKind
}

nonisolated struct MobileSyncTailscaleDetection: Equatable, Sendable, Codable {
    let addresses: [MobileSyncInterfaceAddress]

    var isAvailable: Bool { selectedAddress != nil }

    var selectedAddress: MobileSyncInterfaceAddress? {
        addresses.first(where: MobileSyncTailscaleDetector.isTailscaleAddress)
    }
}

nonisolated enum MobileSyncTailscaleDetector {
    static func detect(addresses: [MobileSyncInterfaceAddress]) -> MobileSyncTailscaleDetection {
        MobileSyncTailscaleDetection(addresses: addresses.filter(isTailscaleAddress))
    }

    static func detectCurrentSystem() -> MobileSyncTailscaleDetection {
        detect(addresses: currentInterfaceAddresses())
    }

    static func isTailscaleAddress(_ address: MobileSyncInterfaceAddress) -> Bool {
        switch address.kind {
        case .ipv4:
            return isTailscaleIPv4(address.address)
        case .ipv6:
            return isTailscaleIPv6(address.address)
        }
    }

    static func isTailscaleIPv4(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    static func isTailscaleIPv6(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private static func currentInterfaceAddresses() -> [MobileSyncInterfaceAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var addresses: [MobileSyncInterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let socketAddress = current.pointee.ifa_addr else { continue }
            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                socketAddress,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else {
                continue
            }

            let interfaceName = current.pointee.ifa_name.map { String(cString: $0) } ?? ""
            addresses.append(
                MobileSyncInterfaceAddress(
                    interfaceName: interfaceName,
                    address: String(cString: host),
                    kind: family == AF_INET ? .ipv4 : .ipv6
                )
            )
        }

        return addresses.sorted {
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName < $1.interfaceName
            }
            return $0.address < $1.address
        }
    }
}

nonisolated struct MobileSyncSettingsSnapshot: Equatable, Sendable, Codable {
    let enabled: Bool
}

enum MobileSyncSettings {
    nonisolated static let enabledKey = "mobileSyncEnabled"
    nonisolated static let defaultEnabled = false

    @MainActor
    static func snapshot(defaults: UserDefaults = .standard) -> MobileSyncSettingsSnapshot {
        guard defaults.object(forKey: enabledKey) != nil else {
            return MobileSyncSettingsSnapshot(enabled: defaultEnabled)
        }
        return MobileSyncSettingsSnapshot(enabled: defaults.bool(forKey: enabledKey))
    }

    @MainActor
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }
}

nonisolated struct MobileSyncStatusSnapshot: Equatable, Sendable, Codable {
    let settings: MobileSyncSettingsSnapshot
    let listenerState: MobileSyncListenerState
    let tailscale: MobileSyncTailscaleDetection
    let workspaceCount: Int
    let terminalCount: Int
    let activeAttachmentCount: Int
}

enum MobileSyncStatusBuilder {
    @MainActor
    static func status(
        tabManager: TabManager?,
        settings: MobileSyncSettingsSnapshot? = nil,
        tailscale: MobileSyncTailscaleDetection? = nil,
        activeAttachmentCount: Int = 0
    ) -> MobileSyncStatusSnapshot {
        let resolvedSettings = settings ?? MobileSyncSettings.snapshot()
        let resolvedTailscale = tailscale ?? MobileSyncTailscaleDetector.detectCurrentSystem()
        let workspaces = tabManager.map(MobileWorkspaceSnapshot.snapshots(from:)) ?? []
        let listenerState: MobileSyncListenerState = {
            guard resolvedSettings.enabled else { return .stopped }
            return resolvedTailscale.isAvailable ? .stopped : .waitingForTailscale
        }()

        return MobileSyncStatusSnapshot(
            settings: resolvedSettings,
            listenerState: listenerState,
            tailscale: resolvedTailscale,
            workspaceCount: workspaces.count,
            terminalCount: workspaces.reduce(0) { $0 + $1.terminals.count },
            activeAttachmentCount: activeAttachmentCount
        )
    }
}

extension MobileSyncStatusSnapshot {
    nonisolated var socketPayload: [String: Any] {
        let selectedAddressValue: Any = tailscale.selectedAddress.map { $0.address as Any } ?? NSNull()
        return [
            "enabled": settings.enabled,
            "listener": [
                "state": listenerState.rawValue,
            ],
            "tailscale": [
                "available": tailscale.isAvailable,
                "selected_address": selectedAddressValue,
                "addresses": tailscale.addresses.map { address in
                    [
                        "interface": address.interfaceName,
                        "address": address.address,
                        "kind": address.kind.rawValue,
                    ]
                },
            ],
            "workspace_count": workspaceCount,
            "terminal_count": terminalCount,
            "active_attachment_count": activeAttachmentCount,
        ]
    }
}
