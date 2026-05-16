import Foundation

// MARK: - Pixel Coordinates

/// Pixel rectangle for external consumption
public struct PixelRect: Codable, Sendable, Equatable {
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

    public init(from cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }
}

// MARK: - Pane Geometry

/// Geometry for a single pane
public struct PaneGeometry: Codable, Sendable, Equatable {
    public let paneId: String
    public let frame: PixelRect
    public let selectedTabId: String?
    public let tabIds: [String]

    public init(paneId: String, frame: PixelRect, selectedTabId: String?, tabIds: [String]) {
        self.paneId = paneId
        self.frame = frame
        self.selectedTabId = selectedTabId
        self.tabIds = tabIds
    }
}

// MARK: - Layout Snapshot

/// Full tree snapshot with pixel coordinates
public struct PaneLayoutSnapshot: Codable, Sendable, Equatable {
    public let containerFrame: PixelRect
    public let panes: [PaneGeometry]
    public let focusedPaneId: String?
    public let timestamp: TimeInterval

    public init(containerFrame: PixelRect, panes: [PaneGeometry], focusedPaneId: String?, timestamp: TimeInterval) {
        self.containerFrame = containerFrame
        self.panes = panes
        self.focusedPaneId = focusedPaneId
        self.timestamp = timestamp
    }
}

// MARK: - External Tree Representation

/// External representation of a tab
public struct ExternalTab: Codable, Sendable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// External representation of a pane node
public struct ExternalPaneNode: Codable, Sendable, Equatable {
    public let id: String
    public let frame: PixelRect
    public let tabs: [ExternalTab]
    public let selectedTabId: String?

    public init(id: String, frame: PixelRect, tabs: [ExternalTab], selectedTabId: String?) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.selectedTabId = selectedTabId
    }
}

/// External representation of a split node
public struct ExternalSplitNode: Codable, Sendable, Equatable {
    public let id: String
    public let orientation: String  // "horizontal" or "vertical"
    public let dividerPosition: Double  // 0.0-1.0
    public let first: ExternalTreeNode
    public let second: ExternalTreeNode

    public init(id: String, orientation: String, dividerPosition: Double, first: ExternalTreeNode, second: ExternalTreeNode) {
        self.id = id
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}

/// External representation of the split tree
public indirect enum ExternalTreeNode: Codable, Sendable, Equatable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)

    // Custom coding keys for enum representation
    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pane":
            let pane = try container.decode(ExternalPaneNode.self, forKey: .pane)
            self = .pane(pane)
        case "split":
            let split = try container.decode(ExternalSplitNode.self, forKey: .split)
            self = .split(split)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let paneNode):
            try container.encode("pane", forKey: .type)
            try container.encode(paneNode, forKey: .pane)
        case .split(let splitNode):
            try container.encode("split", forKey: .type)
            try container.encode(splitNode, forKey: .split)
        }
    }
}
