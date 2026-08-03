public import Foundation

/// Current Mac focus target for mobile Voice Mode.
public struct MobileFocusSnapshot: Codable, Equatable, Sendable {
    /// Focused workspace id, if any.
    public let workspaceID: String?
    /// Short workspace reference, if any.
    public let workspaceRef: String?
    /// Focused workspace title, if any.
    public let workspaceTitle: String?
    /// Focused surface id, if any.
    public let surfaceID: String?
    /// Short surface reference, if any.
    public let surfaceRef: String?
    /// Focused surface title, if any.
    public let surfaceTitle: String?
    /// Focused surface type, if known.
    public let surfaceType: String?
    /// Whether the focused surface is a terminal.
    public let isTerminal: Bool
    /// Optional selected-workspace pane layout for Voice Mode target previews.
    public let layout: MobileFocusSnapshotLayout?

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case workspaceRef = "workspace_ref"
        case workspaceTitle = "workspace_title"
        case surfaceID = "surface_id"
        case surfaceRef = "surface_ref"
        case surfaceTitle = "surface_title"
        case surfaceType = "surface_type"
        case isTerminal = "is_terminal"
        case layout
    }

    /// Creates a focus snapshot.
    public init(
        workspaceID: String?,
        workspaceRef: String?,
        workspaceTitle: String?,
        surfaceID: String?,
        surfaceRef: String?,
        surfaceTitle: String?,
        surfaceType: String?,
        isTerminal: Bool,
        layout: MobileFocusSnapshotLayout? = nil
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.workspaceTitle = workspaceTitle
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.surfaceTitle = surfaceTitle
        self.surfaceType = surfaceType
        self.isTerminal = isTerminal
        self.layout = layout
    }

    /// Decode a snapshot from raw RPC/event JSON.
    /// - Parameter data: JSON object data.
    /// - Returns: The decoded focus snapshot.
    public static func decode(_ data: Data) throws -> MobileFocusSnapshot {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

/// Flat normalized selected-workspace layout for Voice Mode.
public struct MobileFocusSnapshotLayout: Codable, Equatable, Sendable {
    /// Layout representation kind. New Macs currently send `rects`.
    public let kind: String
    /// Pane leaves with normalized rectangles.
    public let panes: [MobileFocusSnapshotLayoutPane]

    /// Creates a layout value.
    public init(kind: String, panes: [MobileFocusSnapshotLayoutPane]) {
        self.kind = kind
        self.panes = panes
    }
}

/// A pane leaf in the Voice Mode layout preview.
public struct MobileFocusSnapshotLayoutPane: Codable, Equatable, Sendable {
    /// Pane representation kind. New Macs currently send `pane`.
    public let kind: String
    /// Selected surface id in this pane, if one exists.
    public let surfaceID: String?
    /// Selected surface title, if one exists.
    public let title: String?
    /// Selected surface type, if known.
    public let surfaceType: String?
    /// Whether the selected surface is a terminal.
    public let isTerminal: Bool
    /// Whether this pane is the Mac's focused target.
    public let focused: Bool
    /// Normalized pane rectangle.
    public let rect: MobileFocusSnapshotLayoutRect

    private enum CodingKeys: String, CodingKey {
        case kind
        case surfaceID = "surface_id"
        case title
        case surfaceType = "surface_type"
        case isTerminal = "is_terminal"
        case focused
        case rect
    }

    /// Creates a pane leaf value.
    public init(
        kind: String,
        surfaceID: String?,
        title: String?,
        surfaceType: String?,
        isTerminal: Bool,
        focused: Bool,
        rect: MobileFocusSnapshotLayoutRect
    ) {
        self.kind = kind
        self.surfaceID = surfaceID
        self.title = title
        self.surfaceType = surfaceType
        self.isTerminal = isTerminal
        self.focused = focused
        self.rect = rect
    }
}

/// Normalized 0...1 rectangle for a Voice Mode pane preview.
public struct MobileFocusSnapshotLayoutRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width = "w"
        case height = "h"
    }

    /// Creates a normalized rect.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
