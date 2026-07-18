/// Mouse lifecycle action encoded against canonical terminal modes.
public enum BackendTerminalMouseAction: String, Equatable, Sendable {
    case press
    case release
    case motion
}

/// Ghostty terminal mouse button and wheel identities.
public enum BackendTerminalMouseButton: String, Equatable, Sendable {
    case left
    case right
    case middle
    case wheelUp = "wheel-up"
    case wheelDown = "wheel-down"
    case wheelLeft = "wheel-left"
    case wheelRight = "wheel-right"
}

/// Pixel and cell geometry used to encode one terminal mouse event.
public struct BackendTerminalMouseEvent: Equatable, Sendable {
    public let action: BackendTerminalMouseAction
    public let button: BackendTerminalMouseButton?
    public let modifiers: UInt16
    public let x: Double
    public let y: Double
    public let viewportWidth: UInt32
    public let viewportHeight: UInt32
    public let cellWidth: UInt32
    public let cellHeight: UInt32
    public let padding: BackendRendererPadding
    public let anyButtonPressed: Bool
    public let clickCount: UInt32

    public init(
        action: BackendTerminalMouseAction,
        button: BackendTerminalMouseButton? = nil,
        modifiers: UInt16 = 0,
        x: Double,
        y: Double,
        viewportWidth: UInt32,
        viewportHeight: UInt32,
        cellWidth: UInt32,
        cellHeight: UInt32,
        padding: BackendRendererPadding,
        anyButtonPressed: Bool = false,
        clickCount: UInt32 = 1
    ) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.x = x
        self.y = y
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.padding = padding
        self.anyButtonPressed = anyButtonPressed
        self.clickCount = clickCount
    }
}

/// Byte count emitted by canonical terminal mouse encoding.
public struct BackendTerminalMouseResponse: Decodable, Equatable, Sendable {
    public let encodedBytes: UInt64
    public let route: BackendTerminalMouseRoute

    private enum CodingKeys: String, CodingKey {
        case encodedBytes = "encoded_bytes"
        case route
    }
}

public enum BackendTerminalMouseRoute: String, Decodable, Equatable, Sendable {
    case application
    case selection
    case scrollback
    case link
}
