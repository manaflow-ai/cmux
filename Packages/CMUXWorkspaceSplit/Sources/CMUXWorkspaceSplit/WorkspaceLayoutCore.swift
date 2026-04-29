import Foundation
import SwiftUI

struct WorkspacePaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    let id: UUID

    init() {
        self.id = UUID()
    }

    init(id: UUID) {
        self.id = id
    }

    var description: String {
        id.uuidString
    }
}

typealias PaneID = WorkspacePaneID

struct WorkspaceTabID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case rawValue
    }

    init() {
        self.rawValue = UUID()
    }

    init(uuid: UUID) {
        self.rawValue = uuid
    }

    var uuid: UUID {
        rawValue
    }

    var description: String {
        rawValue.uuidString
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(UUID.self, forKey: .id) {
            self.rawValue = id
            return
        }
        // Backward compatibility for older payloads encoded as {"rawValue": ...}.
        self.rawValue = try container.decode(UUID.self, forKey: .rawValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Keep field name stable for workspace/session restore compatibility.
        try container.encode(rawValue, forKey: .id)
    }
}

typealias TabID = WorkspaceTabID

enum WorkspaceLayoutOrientation: String, Codable, Sendable {
    case horizontal
    case vertical
}

typealias SplitOrientation = WorkspaceLayoutOrientation

enum WorkspaceNavigationDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

typealias NavigationDirection = WorkspaceNavigationDirection

enum WorkspaceTabContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
    case copyIdentifiers
    case closeToLeft
    case closeToRight
    case closeOthers
    case move
    case moveToLeftPane
    case moveToRightPane
    case newTerminalToRight
    case newBrowserToRight
    case reload
    case duplicate
    case togglePin
    case markAsRead
    case markAsUnread
    case toggleZoom
}

typealias TabContextAction = WorkspaceTabContextAction

struct WorkspacePixelRect: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }
}

typealias PixelRect = WorkspacePixelRect

struct PaneGeometry: Codable, Sendable, Equatable {
    let paneId: String
    let frame: PixelRect
    let selectedTabId: String?
    let tabIds: [String]
}

struct LayoutSnapshot: Codable, Sendable, Equatable {
    let containerFrame: PixelRect
    let panes: [PaneGeometry]
    let focusedPaneId: String?
    let timestamp: TimeInterval
}

struct ExternalTab: Codable, Sendable, Equatable {
    let id: String
    let title: String
}

struct ExternalPaneNode: Codable, Sendable, Equatable {
    let id: String
    let frame: PixelRect
    let tabs: [ExternalTab]
    let selectedTabId: String?
}

struct ExternalSplitNode: Codable, Sendable, Equatable {
    let id: String
    let orientation: String
    let dividerPosition: Double
    let first: ExternalTreeNode
    let second: ExternalTreeNode
}

indirect enum ExternalTreeNode: Codable, Sendable, Equatable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)

    enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(try container.decode(ExternalPaneNode.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(ExternalSplitNode.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported external tree node"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

enum WorkspaceDropZone: Equatable, Sendable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right:
            return .horizontal
        case .top, .bottom:
            return .vertical
        case .center:
            return nil
        }
    }

    var insertFirst: Bool {
        switch self {
        case .left, .top:
            return true
        case .center, .right, .bottom:
            return false
        }
    }
}

typealias DropZone = WorkspaceDropZone

struct PaneDropZoneEnvironmentKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[PaneDropZoneEnvironmentKey.self] }
        set { self[PaneDropZoneEnvironmentKey.self] = newValue }
    }
}

enum NewTabPosition: Sendable {
    case current
    case end
}
