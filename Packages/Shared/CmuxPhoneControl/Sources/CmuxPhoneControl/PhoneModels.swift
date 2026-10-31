import Foundation

public struct PhoneDisplayGeometry: Codable, Equatable, Sendable {
    public enum Orientation: String, Codable, Sendable {
        case portrait
        case portraitUpsideDown = "portrait_upside_down"
        case landscapeLeft = "landscape_left"
        case landscapeRight = "landscape_right"
    }

    public let width: Int
    public let height: Int
    public let scale: Double
    public let orientation: Orientation
    public let safeInsets: Insets

    public init(
        width: Int,
        height: Int,
        scale: Double = 1,
        orientation: Orientation = .portrait,
        safeInsets: Insets = .zero
    ) {
        self.width = width
        self.height = height
        self.scale = scale
        self.orientation = orientation
        self.safeInsets = safeInsets
    }

    public struct Insets: Codable, Equatable, Sendable {
        public let top: Double
        public let left: Double
        public let bottom: Double
        public let right: Double

        public static let zero = Self(top: 0, left: 0, bottom: 0, right: 0)

        public init(top: Double, left: Double, bottom: Double, right: Double) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }
    }
}

public enum PhoneSource: String, Codable, Sendable {
    case mock
    case webDriverAgent = "webdriver_agent"
    case iphoneMirroring = "iphone_mirroring"
}

public struct PhoneCapabilities: Codable, Equatable, Sendable {
    public let screenSnapshot: Bool
    public let screenStream: Bool
    public let accessibilityTree: Bool
    public let tap: Bool
    public let swipe: Bool
    public let typing: Bool
    public let physicalButtons: Bool

    public init(
        screenSnapshot: Bool,
        screenStream: Bool = false,
        accessibilityTree: Bool = false,
        tap: Bool = false,
        swipe: Bool = false,
        typing: Bool = false,
        physicalButtons: Bool = false
    ) {
        self.screenSnapshot = screenSnapshot
        self.screenStream = screenStream
        self.accessibilityTree = accessibilityTree
        self.tap = tap
        self.swipe = swipe
        self.typing = typing
        self.physicalButtons = physicalButtons
    }
}

public struct PhoneDevice: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case available
        case needsPermission = "needs_permission"
        case unavailable
    }

    public let id: String
    public let name: String
    public let model: String
    public let osVersion: String
    public let source: PhoneSource
    public let state: State
    public let geometry: PhoneDisplayGeometry
    public let capabilities: PhoneCapabilities

    public init(
        id: String,
        name: String,
        model: String,
        osVersion: String,
        source: PhoneSource,
        state: State,
        geometry: PhoneDisplayGeometry,
        capabilities: PhoneCapabilities
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.source = source
        self.state = state
        self.geometry = geometry
        self.capabilities = capabilities
    }
}

public struct PhoneScreenFrame: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let orientation: PhoneDisplayGeometry.Orientation
    public let format: String
    public let data: Data

    public init(
        sequence: UInt64,
        timestamp: Double = Date().timeIntervalSince1970,
        width: Int,
        height: Int,
        orientation: PhoneDisplayGeometry.Orientation,
        format: String = "png",
        data: Data
    ) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.orientation = orientation
        self.format = format
        self.data = data
    }
}

public struct PhoneUIElement: Codable, Equatable, Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let value: String?
    public let enabled: Bool
    public let visible: Bool
    public let bounds: Bounds
    public let actions: [String]
    public let children: [PhoneUIElement]

    public struct Bounds: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(
        id: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        enabled: Bool = true,
        visible: Bool = true,
        bounds: Bounds,
        actions: [String] = [],
        children: [PhoneUIElement] = []
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.enabled = enabled
        self.visible = visible
        self.bounds = bounds
        self.actions = actions
        self.children = children
    }
}

public struct PhoneActionReceipt: Codable, Equatable, Sendable {
    public let actionID: String
    public let accepted: Bool
    public let duplicate: Bool
    public let screenSequence: UInt64
    public let detail: String?

    public init(
        actionID: String,
        accepted: Bool,
        duplicate: Bool = false,
        screenSequence: UInt64,
        detail: String? = nil
    ) {
        self.actionID = actionID
        self.accepted = accepted
        self.duplicate = duplicate
        self.screenSequence = screenSequence
        self.detail = detail
    }
}

public enum PhoneActionKind: String, Codable, Sendable {
    case tap
    case swipe
    case longPress = "long_press"
    case type
    case press
}

public struct PhonePoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    @discardableResult
    public func validated() throws -> Self {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw PhoneError(code: "invalid_coordinates", message: "normalized coordinates must be within [0, 1]")
        }
        return self
    }
}

public struct PhoneActionRequest: Codable, Equatable, Sendable {
    public let actionID: String
    public let kind: PhoneActionKind
    public let screenSequence: UInt64?
    public let point: PhonePoint?
    public let endPoint: PhonePoint?
    public let durationMilliseconds: Int?
    public let text: String?
    public let button: String?

    public init(
        actionID: String,
        kind: PhoneActionKind,
        screenSequence: UInt64? = nil,
        point: PhonePoint? = nil,
        endPoint: PhonePoint? = nil,
        durationMilliseconds: Int? = nil,
        text: String? = nil,
        button: String? = nil
    ) {
        self.actionID = actionID
        self.kind = kind
        self.screenSequence = screenSequence
        self.point = point
        self.endPoint = endPoint
        self.durationMilliseconds = durationMilliseconds
        self.text = text
        self.button = button
    }

    @discardableResult
    public func validated() throws -> Self {
        guard !actionID.isEmpty, actionID.utf8.count <= 256 else {
            throw PhoneError(code: "invalid_action", message: "action_id is required and must be at most 256 bytes")
        }
        if let durationMilliseconds {
            guard (1...60_000).contains(durationMilliseconds) else {
                throw PhoneError(code: "invalid_action", message: "duration_ms must be between 1 and 60000")
            }
        }
        switch kind {
        case .tap, .longPress:
            guard let point, endPoint == nil else {
                throw PhoneError(code: "invalid_action", message: "\(kind.rawValue) requires point")
            }
            try point.validated()
        case .swipe:
            guard let point, let endPoint else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
            try point.validated()
            try endPoint.validated()
        case .type:
            guard let text, !text.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "type requires non-empty text")
            }
        case .press:
            guard let button, !button.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "press requires button")
            }
        }
        return self
    }
}
