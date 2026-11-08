public struct MobileSimulatorPanelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: String { panelID }

    public let panelID: String
    public let workspaceID: String
    public let title: String
    public let selectedDeviceName: String?
    public let selectedDeviceState: String?
    public let status: String
    public let isReady: Bool
    public let supportsTouch: Bool
    public let supportsKeyboard: Bool
    public let supportsHardwareButtons: Bool
    public let supportsRotation: Bool
    public let ownerConnectionID: String?
    /// Whether the receiving connection owns the pane's control lock.
    /// `nil` means "not personalized": the descriptor was built for a shared
    /// payload (state-sync rows, workspace lists) that fans out to every
    /// phone, so it cannot say anything about *this* connection. Receivers
    /// keep their last per-connection answer (stream start response,
    /// `simulator.state` events, `mobile.simulator.list`) when this is `nil`.
    public let isOwnedByCurrentConnection: Bool?

    public init(
        panelID: String,
        workspaceID: String,
        title: String,
        selectedDeviceName: String?,
        selectedDeviceState: String?,
        status: String,
        isReady: Bool,
        supportsTouch: Bool,
        supportsKeyboard: Bool,
        supportsHardwareButtons: Bool,
        supportsRotation: Bool,
        ownerConnectionID: String? = nil,
        isOwnedByCurrentConnection: Bool? = nil
    ) {
        self.panelID = panelID
        self.workspaceID = workspaceID
        self.title = title
        self.selectedDeviceName = selectedDeviceName
        self.selectedDeviceState = selectedDeviceState
        self.status = status
        self.isReady = isReady
        self.supportsTouch = supportsTouch
        self.supportsKeyboard = supportsKeyboard
        self.supportsHardwareButtons = supportsHardwareButtons
        self.supportsRotation = supportsRotation
        self.ownerConnectionID = ownerConnectionID
        self.isOwnedByCurrentConnection = isOwnedByCurrentConnection
    }

    private enum CodingKeys: String, CodingKey {
        case panelID = "panel_id"
        case workspaceID = "workspace_id"
        case title
        case selectedDeviceName = "selected_device_name"
        case selectedDeviceState = "selected_device_state"
        case status
        case isReady = "is_ready"
        case supportsTouch = "supports_touch"
        case supportsKeyboard = "supports_keyboard"
        case supportsHardwareButtons = "supports_hardware_buttons"
        case supportsRotation = "supports_rotation"
        case ownerConnectionID = "owner_connection_id"
        case isOwnedByCurrentConnection = "is_owned_by_current_connection"
    }
}
