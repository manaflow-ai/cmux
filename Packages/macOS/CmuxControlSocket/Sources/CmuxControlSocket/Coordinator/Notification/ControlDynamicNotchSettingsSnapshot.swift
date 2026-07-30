/// Agent-facing Dynamic Notch defaults returned by the control socket.
public struct ControlDynamicNotchSettingsSnapshot: Equatable, Sendable {
    public let enabled: Bool
    public let horizontalPosition: Double
    public let displays: [ControlDynamicNotchDisplaySnapshot]

    public init(
        enabled: Bool,
        horizontalPosition: Double,
        displays: [ControlDynamicNotchDisplaySnapshot] = []
    ) {
        self.enabled = enabled
        self.horizontalPosition = horizontalPosition
        self.displays = displays
    }
}

/// One connected display and its resolved Dynamic Notch placement.
public struct ControlDynamicNotchDisplaySnapshot: Equatable, Sendable {
    public let key: String
    public let id: UInt32?
    public let name: String
    public let hasHardwareNotch: Bool
    public let horizontalPosition: Double
    public let hasPositionOverride: Bool

    public init(
        key: String,
        id: UInt32?,
        name: String,
        hasHardwareNotch: Bool,
        horizontalPosition: Double,
        hasPositionOverride: Bool
    ) {
        self.key = key
        self.id = id
        self.name = name
        self.hasHardwareNotch = hasHardwareNotch
        self.horizontalPosition = horizontalPosition
        self.hasPositionOverride = hasPositionOverride
    }
}
