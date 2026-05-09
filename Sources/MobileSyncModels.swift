import Darwin
import CoreGraphics
import Foundation
import Network
import CMUXMobileSyncCore

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

nonisolated struct TerminalSizeOverlaySnapshot: Equatable, Sendable, Codable {
    let localSize: TerminalGridSize
    let effectiveSize: TerminalGridSize
    let surfaceKind: TerminalAttachmentSurfaceKind
    let deviceName: String?
    let activeAttachmentCount: Int

    var isRemotelyConstrained: Bool {
        activeAttachmentCount > 0 &&
            (effectiveSize.columns < localSize.columns || effectiveSize.rows < localSize.rows)
    }

    var socketPayload: [String: Any] {
        [
            "visible": isRemotelyConstrained,
            "local": [
                "columns": localSize.columns,
                "rows": localSize.rows,
            ],
            "effective": [
                "columns": effectiveSize.columns,
                "rows": effectiveSize.rows,
            ],
            "surface_kind": surfaceKind.rawValue,
            "device_name": deviceName ?? NSNull(),
            "active_attachment_count": activeAttachmentCount,
        ]
    }
}

nonisolated struct TerminalSizeOverlayGeometry: Equatable, Sendable {
    let containerRect: CGRect
    let activeRect: CGRect
    let isVisible: Bool

    static let hidden = TerminalSizeOverlayGeometry(
        containerRect: .zero,
        activeRect: .zero,
        isVisible: false
    )

    static func resolve(
        containerSize: CGSize,
        cellSize: CGSize,
        snapshot: TerminalSizeOverlaySnapshot?
    ) -> TerminalSizeOverlayGeometry {
        guard let snapshot,
              snapshot.isRemotelyConstrained,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .hidden
        }

        let localColumns = max(snapshot.localSize.columns, 1)
        let localRows = max(snapshot.localSize.rows, 1)
        let resolvedCellWidth = cellSize.width > 0
            ? cellSize.width
            : containerSize.width / CGFloat(localColumns)
        let resolvedCellHeight = cellSize.height > 0
            ? cellSize.height
            : containerSize.height / CGFloat(localRows)
        let activeWidth = min(
            containerSize.width,
            max(1, CGFloat(snapshot.effectiveSize.columns) * resolvedCellWidth)
        )
        let activeHeight = min(
            containerSize.height,
            max(1, CGFloat(snapshot.effectiveSize.rows) * resolvedCellHeight)
        )
        let activeRect = CGRect(
            x: 0,
            y: max(0, containerSize.height - activeHeight),
            width: activeWidth,
            height: activeHeight
        )

        return TerminalSizeOverlayGeometry(
            containerRect: CGRect(origin: .zero, size: containerSize),
            activeRect: activeRect,
            isVisible: activeWidth < containerSize.width || activeHeight < containerSize.height
        )
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
    nonisolated static let didChangeNotification = Notification.Name("cmux.mobileSyncSettingsDidChange")

    @MainActor
    static func snapshot(defaults: UserDefaults = .standard) -> MobileSyncSettingsSnapshot {
        guard defaults.object(forKey: enabledKey) != nil else {
            return MobileSyncSettingsSnapshot(enabled: defaultEnabled)
        }
        return MobileSyncSettingsSnapshot(enabled: defaults.bool(forKey: enabledKey))
    }

    @MainActor
    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        let previous = snapshot(defaults: defaults).enabled
        defaults.set(enabled, forKey: enabledKey)
        guard previous != enabled else { return }
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

enum MobileSyncActions {
    @MainActor
    static func enable(
        tabManager: TabManager?,
        defaults: UserDefaults = .standard,
        tailscale: MobileSyncTailscaleDetection? = nil
    ) -> MobileSyncStatusSnapshot {
        setEnabled(true, tabManager: tabManager, defaults: defaults, tailscale: tailscale)
    }

    @MainActor
    static func disable(
        tabManager: TabManager?,
        defaults: UserDefaults = .standard,
        tailscale: MobileSyncTailscaleDetection? = nil
    ) -> MobileSyncStatusSnapshot {
        setEnabled(false, tabManager: tabManager, defaults: defaults, tailscale: tailscale)
    }

    @MainActor
    static func setEnabled(
        _ enabled: Bool,
        tabManager: TabManager?,
        defaults: UserDefaults = .standard,
        tailscale: MobileSyncTailscaleDetection? = nil
    ) -> MobileSyncStatusSnapshot {
        MobileSyncSettings.setEnabled(enabled, defaults: defaults)
        return status(tabManager: tabManager, defaults: defaults, tailscale: tailscale)
    }

    @MainActor
    static func status(
        tabManager: TabManager?,
        defaults: UserDefaults = .standard,
        tailscale: MobileSyncTailscaleDetection? = nil,
        activeAttachmentCount: Int = 0
    ) -> MobileSyncStatusSnapshot {
        MobileSyncStatusBuilder.status(
            tabManager: tabManager,
            settings: MobileSyncSettings.snapshot(defaults: defaults),
            tailscale: tailscale,
            activeAttachmentCount: activeAttachmentCount
        )
    }
}

nonisolated struct MobileSyncStatusSnapshot: Equatable, Sendable, Codable {
    let settings: MobileSyncSettingsSnapshot
    let listenerState: MobileSyncListenerState
    let tailscale: MobileSyncTailscaleDetection
    let workspaceCount: Int
    let terminalCount: Int
    let activeAttachmentCount: Int
    let listenerHost: String?
    let listenerPort: Int?
    let pairingURL: String?
    let debugLoopback: Bool

    init(
        settings: MobileSyncSettingsSnapshot,
        listenerState: MobileSyncListenerState,
        tailscale: MobileSyncTailscaleDetection,
        workspaceCount: Int,
        terminalCount: Int,
        activeAttachmentCount: Int,
        listenerHost: String? = nil,
        listenerPort: Int? = nil,
        pairingURL: String? = nil,
        debugLoopback: Bool = false
    ) {
        self.settings = settings
        self.listenerState = listenerState
        self.tailscale = tailscale
        self.workspaceCount = workspaceCount
        self.terminalCount = terminalCount
        self.activeAttachmentCount = activeAttachmentCount
        self.listenerHost = listenerHost
        self.listenerPort = listenerPort
        self.pairingURL = pairingURL
        self.debugLoopback = debugLoopback
    }
}

enum MobileSyncStatusBuilder {
    @MainActor
    static func status(
        tabManager: TabManager?,
        settings: MobileSyncSettingsSnapshot? = nil,
        defaults: UserDefaults = .standard,
        tailscale: MobileSyncTailscaleDetection? = nil,
        activeAttachmentCount: Int = 0
    ) -> MobileSyncStatusSnapshot {
        let resolvedSettings = settings ?? MobileSyncSettings.snapshot(defaults: defaults)
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
        let listenerHostValue: Any = listenerHost.map { $0 as Any } ?? NSNull()
        let listenerPortValue: Any = listenerPort.map { $0 as Any } ?? NSNull()
        let pairingURLValue: Any = pairingURL.map { $0 as Any } ?? NSNull()
        return [
            "enabled": settings.enabled,
            "listener": [
                "state": listenerState.rawValue,
                "host": listenerHostValue,
                "port": listenerPortValue,
                "debug_loopback": debugLoopback,
            ],
            "pairing_url": pairingURLValue,
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

enum MobileSyncServerError: Error, LocalizedError {
    case listenerFailed(String)
    case missingPort
    case invalidPairingPayload

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return message
        case .missingPort:
            return "Mobile sync listener did not report a port"
        case .invalidPairingPayload:
            return "Mobile sync pairing payload could not be created"
        }
    }
}

final class MobileSyncServer {
    typealias RequestHandler = ([String: Any]) -> [String: Any]

    private let host: String
    private let handler: RequestHandler
    private let queue = DispatchQueue(label: "com.cmux.mobile-sync.server")
    private var listener: NWListener?
    private var connections: [UUID: MobileSyncServerConnection] = [:]

    private(set) var port: Int?

    init(host: String, handler: @escaping RequestHandler) {
        self.host = host
        self.handler = handler
    }

    func start(timeout: TimeInterval = 2.0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let failure = LockedValue<Error?>(nil)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port.map { Int($0.rawValue) }
                ready.signal()
            case .failed(let error):
                failure.set(MobileSyncServerError.listenerFailed(error.localizedDescription))
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            stop()
            throw MobileSyncServerError.listenerFailed("Timed out starting mobile sync listener")
        }
        if let error = failure.value {
            stop()
            throw error
        }
        guard port != nil else {
            stop()
            throw MobileSyncServerError.missingPort
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        let activeConnections = Array(connections.values)
        connections.removeAll()
        for connection in activeConnections {
            connection.cancel()
        }
        port = nil
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = MobileSyncServerConnection(connection: connection, handler: handler) { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = session
        session.start(on: queue)
    }
}

private final class MobileSyncServerConnection {
    private let connection: NWConnection
    private let handler: MobileSyncServer.RequestHandler
    private let onClose: () -> Void
    private var buffer = Data()
    private var didClose = false

    init(
        connection: NWConnection,
        handler: @escaping MobileSyncServer.RequestHandler,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        close()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBufferedFrames()
            }
            if error != nil || isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func processBufferedFrames() {
        do {
            let frames = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
            for frame in frames {
                send(responsePayload(for: frame))
            }
        } catch {
            send(errorEnvelope(id: nil, code: "invalid_frame", message: error.localizedDescription))
            close()
        }
    }

    private func responsePayload(for frame: Data) -> Data {
        let id: Any?
        do {
            guard let request = try JSONSerialization.jsonObject(with: frame) as? [String: Any] else {
                return errorEnvelope(id: nil, code: "invalid_json", message: "Request must be a JSON object")
            }
            id = request["id"]
            let result = handler(request)
            if let error = result["error"] as? [String: Any] {
                return errorEnvelope(id: id, error: error)
            }
            let envelope: [String: Any] = [
                "id": id ?? NSNull(),
                "ok": true,
                "result": result,
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        } catch {
            return errorEnvelope(id: nil, code: "invalid_request", message: error.localizedDescription)
        }
    }

    private func errorEnvelope(id: Any?, code: String, message: String) -> Data {
        let envelope: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": false,
            "error": [
                "code": code,
                "message": message,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    private func errorEnvelope(id: Any?, error: [String: Any]) -> Data {
        let envelope: [String: Any] = [
            "id": id ?? NSNull(),
            "ok": false,
            "error": error,
        ]
        return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
    }

    private func send(_ payload: Data) {
        do {
            let frame = try MobileSyncFrameCodec.encodeFrame(payload)
            connection.send(content: frame, completion: .contentProcessed { _ in })
        } catch {
            close()
        }
    }

    private func close() {
        guard !didClose else { return }
        didClose = true
        connection.cancel()
        onClose()
    }
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

@MainActor
final class MobileSyncServerController {
    static let shared = MobileSyncServerController()

    private var server: MobileSyncServer?
    private var listenerHost: String?
    private var listenerPort: Int?
    private var pairingURL: String?
    private var debugLoopback = false

    private init() {}

    func status(tabManager: TabManager?) -> MobileSyncStatusSnapshot {
        let settings = MobileSyncSettings.snapshot()
        if settings.enabled {
            reconcileStarted(tabManager: tabManager)
        } else {
            stop()
        }
        return snapshot(tabManager: tabManager)
    }

    func enable(tabManager: TabManager?) -> MobileSyncStatusSnapshot {
        MobileSyncSettings.setEnabled(true)
        reconcileStarted(tabManager: tabManager)
        return snapshot(tabManager: tabManager)
    }

    func disable(tabManager: TabManager?) -> MobileSyncStatusSnapshot {
        MobileSyncSettings.setEnabled(false)
        stop()
        return snapshot(tabManager: tabManager)
    }

    private func reconcileStarted(tabManager: TabManager?) {
        guard server == nil else { return }
        let tailscale = MobileSyncTailscaleDetector.detectCurrentSystem()
        let bind = bindTarget(tailscale: tailscale)
        guard let bind else {
            listenerHost = nil
            listenerPort = nil
            pairingURL = nil
            debugLoopback = false
            return
        }

        let nextServer = MobileSyncServer(host: bind.host) { [weak tabManager] request in
            Self.handle(request: request, tabManager: tabManager)
        }
        do {
            try nextServer.start()
            server = nextServer
            listenerHost = bind.host
            listenerPort = nextServer.port
            debugLoopback = bind.debugLoopback
            pairingURL = makePairingURL(
                host: bind.host,
                port: nextServer.port,
                debugLoopback: bind.debugLoopback
            )
        } catch {
            nextServer.stop()
            server = nil
            listenerHost = nil
            listenerPort = nil
            pairingURL = nil
            debugLoopback = false
        }
    }

    private func stop() {
        server?.stop()
        server = nil
        listenerHost = nil
        listenerPort = nil
        pairingURL = nil
        debugLoopback = false
    }

    private func snapshot(tabManager: TabManager?) -> MobileSyncStatusSnapshot {
        let settings = MobileSyncSettings.snapshot()
        let tailscale = MobileSyncTailscaleDetector.detectCurrentSystem()
        let workspaces = tabManager.map(MobileWorkspaceSnapshot.snapshots(from:)) ?? []
        let listenerState: MobileSyncListenerState = {
            guard settings.enabled else { return .stopped }
            if server != nil { return .listening }
            return tailscale.isAvailable ? .stopped : .waitingForTailscale
        }()
        return MobileSyncStatusSnapshot(
            settings: settings,
            listenerState: listenerState,
            tailscale: tailscale,
            workspaceCount: workspaces.count,
            terminalCount: workspaces.reduce(0) { $0 + $1.terminals.count },
            activeAttachmentCount: 0,
            listenerHost: listenerHost,
            listenerPort: listenerPort,
            pairingURL: pairingURL,
            debugLoopback: debugLoopback
        )
    }

    private struct BindTarget {
        let host: String
        let debugLoopback: Bool
    }

    private func bindTarget(tailscale: MobileSyncTailscaleDetection) -> BindTarget? {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_MOBILE_SYNC_DEBUG_LOOPBACK"] == "1" {
            return BindTarget(host: "127.0.0.1", debugLoopback: true)
        }
#endif
        guard let address = tailscale.selectedAddress else { return nil }
        return BindTarget(host: address.address, debugLoopback: false)
    }

    private func makePairingURL(host: String, port: Int?, debugLoopback: Bool) -> String? {
        guard let port else { return nil }
        let hostName = ProcessInfo.processInfo.hostName
        let payload = try? MobileSyncPairingPayload(
            macDeviceID: hostName.isEmpty ? "cmux-mac" : hostName,
            macDisplayName: hostName.isEmpty ? nil : hostName,
            host: host,
            port: port,
            expiresAt: Date().addingTimeInterval(10 * 60),
            transport: debugLoopback ? .debugLoopback : .tailscale
        )
        return try? payload?.encodedURL().absoluteString
    }

    private static func handle(request: [String: Any], tabManager: TabManager?) -> [String: Any] {
        let method = request["method"] as? String
        switch method {
        case "system.ping":
            return ["pong": true]
        case "workspace.list", "mobile_sync.workspace_list":
            return workspaceListPayload(tabManager: tabManager)
        case "workspace.create", "mobile_sync.workspace_create":
            return createWorkspacePayload(request: request, tabManager: tabManager)
        case "terminal.create", "mobile_sync.terminal_create":
            return createTerminalPayload(request: request, tabManager: tabManager)
        case "terminal.input", "mobile_sync.terminal_input":
            return terminalInputPayload(request: request, tabManager: tabManager)
        case "terminal.snapshot", "mobile_sync.terminal_snapshot":
            return terminalSnapshotPayload(request: request, tabManager: tabManager)
        default:
            return [
                "error": [
                    "code": "unknown_method",
                    "message": "Unknown mobile sync method",
                ],
            ]
        }
    }

    private static func workspaceListPayload(tabManager: TabManager?) -> [String: Any] {
        var payload: [String: Any] = ["workspaces": []]
        DispatchQueue.main.sync {
            let workspaces = tabManager.map(MobileWorkspaceSnapshot.snapshots(from:)) ?? []
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(workspaces),
                  let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return
            }
            payload = [
                "workspaces": objects,
                "workspace_count": objects.count,
                "terminal_count": workspaces.reduce(0) { $0 + $1.terminals.count },
            ]
        }
        return payload
    }

    private static func createWorkspacePayload(request: [String: Any], tabManager: TabManager?) -> [String: Any] {
        var payload = errorPayload(code: "unavailable", message: "TabManager not available")
        DispatchQueue.main.sync {
            guard let tabManager else { return }
            let params = requestParams(request)
            let title = normalizedString(params["title"])
            let workingDirectory = normalizedString(params["working_directory"])
            let initialInput = normalizedString(params["initial_input"])
            let workspace = tabManager.addWorkspace(
                title: title,
                workingDirectory: workingDirectory,
                initialTerminalInput: initialInput,
                select: true,
                eagerLoadTerminal: true
            )
            payload = workspaceListPayloadOnMain(tabManager: tabManager)
            payload["created_workspace_id"] = workspace.id.uuidString
            payload["created_terminal_id"] = workspace.focusedTerminalPanel?.id.uuidString ?? NSNull()
        }
        return payload
    }

    private static func createTerminalPayload(request: [String: Any], tabManager: TabManager?) -> [String: Any] {
        var payload = errorPayload(code: "unavailable", message: "TabManager not available")
        DispatchQueue.main.sync {
            guard let tabManager else { return }
            let params = requestParams(request)
            guard let workspace = resolveWorkspace(params: params, tabManager: tabManager) else {
                payload = errorPayload(code: "not_found", message: "Workspace not found")
                return
            }
            tabManager.selectedTabId = workspace.id
            workspace.clearSplitZoom()
            guard let terminal = workspace.newTerminalSurfaceInFocusedPane(
                focus: true,
                initialInput: normalizedString(params["initial_input"])
            ) else {
                payload = errorPayload(code: "internal_error", message: "Failed to create terminal")
                return
            }
            payload = workspaceListPayloadOnMain(tabManager: tabManager)
            payload["created_workspace_id"] = workspace.id.uuidString
            payload["created_terminal_id"] = terminal.id.uuidString
        }
        return payload
    }

    private static func terminalInputPayload(request: [String: Any], tabManager: TabManager?) -> [String: Any] {
        var payload = errorPayload(code: "unavailable", message: "TabManager not available")
        DispatchQueue.main.sync {
            guard let tabManager else { return }
            let params = requestParams(request)
            guard let text = params["text"] as? String, !text.isEmpty else {
                payload = errorPayload(code: "invalid_params", message: "Missing text")
                return
            }
            guard let workspace = resolveWorkspace(params: params, tabManager: tabManager) else {
                payload = errorPayload(code: "not_found", message: "Workspace not found")
                return
            }
            let terminalID = normalizedString(params["surface_id"])
                .flatMap(UUID.init(uuidString:))
                ?? normalizedString(params["terminal_id"]).flatMap(UUID.init(uuidString:))
                ?? workspace.focusedPanelId
            guard let terminalID,
                  let terminal = workspace.terminalPanel(for: terminalID) else {
                payload = errorPayload(code: "not_found", message: "Terminal not found")
                return
            }
            terminal.sendText(text)
            if terminal.surface.surface != nil {
                terminal.surface.forceRefresh(reason: "mobileSync.terminalInput")
            }
            payload = [
                "workspace_id": workspace.id.uuidString,
                "surface_id": terminal.id.uuidString,
                "accepted": true,
            ]
        }
        return payload
    }

    private static func terminalSnapshotPayload(request: [String: Any], tabManager: TabManager?) -> [String: Any] {
        var payload = errorPayload(code: "unavailable", message: "TabManager not available")
        DispatchQueue.main.sync {
            guard let tabManager else { return }
            let params = requestParams(request)
            guard let workspace = resolveWorkspace(params: params, tabManager: tabManager) else {
                payload = errorPayload(code: "not_found", message: "Workspace not found")
                return
            }
            let terminalID = normalizedString(params["surface_id"])
                .flatMap(UUID.init(uuidString:))
                ?? normalizedString(params["terminal_id"]).flatMap(UUID.init(uuidString:))
                ?? workspace.focusedPanelId
            guard let terminalID,
                  let terminal = workspace.terminalPanel(for: terminalID) else {
                payload = errorPayload(code: "not_found", message: "Terminal not found")
                return
            }
            let maxScrollbackRows = max(
                1,
                min(intValue(params["max_scrollback_rows"]) ?? 500, 10_000)
            )
            do {
                let snapshot = try MobileTerminalGhosttySnapshotExporter.snapshot(
                    terminalPanel: terminal,
                    maxScrollbackRows: maxScrollbackRows
                )
                let encoded = try snapshot.encodedValidatedJSON()
                guard let snapshotObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                    payload = errorPayload(code: "internal_error", message: "Failed to encode terminal snapshot")
                    return
                }
                payload = [
                    "snapshot": snapshotObject,
                    "snapshot_base64": encoded.base64EncodedString(),
                    "schema_version": MobileTerminalGhosttySnapshot.currentSchemaVersion,
                    "max_scrollback_rows": maxScrollbackRows,
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": terminal.id.uuidString,
                ]
            } catch {
                payload = errorPayload(
                    code: "internal_error",
                    message: "Failed to build terminal snapshot: \(error.localizedDescription)"
                )
            }
        }
        return payload
    }

    private static func workspaceListPayloadOnMain(tabManager: TabManager?) -> [String: Any] {
        let workspaces = tabManager.map(MobileWorkspaceSnapshot.snapshots(from:)) ?? []
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(workspaces),
              let objects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ["workspaces": []]
        }
        return [
            "workspaces": objects,
            "workspace_count": objects.count,
            "terminal_count": workspaces.reduce(0) { $0 + $1.terminals.count },
        ]
    }

    private static func requestParams(_ request: [String: Any]) -> [String: Any] {
        request["params"] as? [String: Any] ?? request
    }

    private static func resolveWorkspace(params: [String: Any], tabManager: TabManager) -> Workspace? {
        if let workspaceID = normalizedString(params["workspace_id"]).flatMap(UUID.init(uuidString:)) {
            return tabManager.tabs.first { $0.id == workspaceID }
        }
        return tabManager.selectedWorkspace ?? tabManager.tabs.first
    }

    private static func normalizedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func errorPayload(code: String, message: String) -> [String: Any] {
        [
            "error": [
                "code": code,
                "message": message,
            ],
        ]
    }
}

enum MobileTerminalGhosttySnapshotExporter {
    @MainActor
    static func snapshot(
        terminalPanel: TerminalPanel,
        maxScrollbackRows: Int
    ) throws -> MobileTerminalGhosttySnapshot {
        guard let surface = terminalPanel.surface.liveSurfaceForGhosttyAccess(reason: "mobileSync.terminalSnapshot") else {
            throw MobileTerminalSnapshotExportError.surfaceUnavailable
        }
        let surfaceSize = ghostty_surface_size(surface)
        let columns = Int(surfaceSize.columns)
        let rows = Int(surfaceSize.rows)
        guard columns > 0, rows > 0 else {
            throw MobileTerminalSnapshotExportError.invalidGridSize
        }
        guard let viewportText = readGhosttySelectionText(surface: surface, pointTag: GHOSTTY_POINT_VIEWPORT) else {
            throw MobileTerminalSnapshotExportError.viewportUnavailable
        }
        let scrollbackText = readGhosttySelectionText(surface: surface, pointTag: GHOSTTY_POINT_SURFACE) ?? ""
        let activeScreen: MobileTerminalGhosttyScreen = {
            switch ghostty_surface_active_screen(surface) {
            case GHOSTTY_SURFACE_SCREEN_ALTERNATE:
                return .alternate
            default:
                return .primary
            }
        }()
        return try MobileTerminalGhosttySnapshot.fromGhosttyText(
            terminalID: terminalPanel.id.uuidString,
            columns: columns,
            rows: rows,
            scrollbackText: scrollbackText,
            viewportText: viewportText,
            maxScrollbackRows: maxScrollbackRows,
            activeScreen: activeScreen,
            streamOffset: 0
        )
    }

    private static func readGhosttySelectionText(surface: ghostty_surface_t, pointTag: ghostty_point_tag_e) -> String? {
        let topLeft = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        )
        let bottomRight = ghostty_point_s(
            tag: pointTag,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        )
        let selection = ghostty_selection_s(
            top_left: topLeft,
            bottom_right: bottomRight,
            rectangle: false
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer {
            ghostty_surface_free_text(surface, &text)
        }

        guard let ptr = text.text, text.text_len > 0 else {
            return ""
        }
        let rawData = Data(bytes: ptr, count: Int(text.text_len))
        return String(decoding: rawData, as: UTF8.self)
    }

    private enum MobileTerminalSnapshotExportError: LocalizedError {
        case surfaceUnavailable
        case invalidGridSize
        case viewportUnavailable

        var errorDescription: String? {
            switch self {
            case .surfaceUnavailable:
                return "Terminal surface is unavailable"
            case .invalidGridSize:
                return "Terminal grid size is invalid"
            case .viewportUnavailable:
                return "Terminal viewport is unavailable"
            }
        }
    }
}
