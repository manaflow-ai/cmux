import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Zone

enum DropZone: Equatable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        case .center: return nil
        }
    }

    var insertsFirst: Bool {
        switch self {
        case .left, .top: return true
        default: return false
        }
    }
}

private struct ActiveDropZoneKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[ActiveDropZoneKey.self] }
        set { self[ActiveDropZoneKey.self] = newValue }
    }
}

// MARK: - Paper Viewport Offset Environment Key

/// The current horizontal viewport offset of the paper layout.
/// Used by the terminal portal system to adjust anchor positions since
/// SwiftUI's .offset() uses CALayer transforms that are invisible to
/// NSView.convert(_:to:nil).
private struct PaperViewportOffsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var paperViewportOffset: CGFloat {
        get { self[PaperViewportOffsetKey.self] }
        set { self[PaperViewportOffsetKey.self] = newValue }
    }
}

// MARK: - Pane ID

/// Opaque identifier for panes
struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
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

// MARK: - Tab ID

/// Opaque identifier for tabs
struct TabID: Hashable, Codable, Sendable {
    internal let id: UUID

    init() {
        self.id = UUID()
    }

    init(uuid: UUID) {
        self.id = uuid
    }

    var uuid: UUID {
        id
    }

    internal init(id: UUID) {
        self.id = id
    }
}

// MARK: - Tab

/// Represents a tab's metadata (read-only snapshot for consumers).
/// Named PaperTab to avoid conflict with SwiftUI.Tab.
struct PaperTab: Identifiable, Hashable, Sendable {
    let id: TabID
    let title: String
    let hasCustomTitle: Bool
    let icon: String?
    let iconImageData: Data?
    let kind: String?
    let isDirty: Bool
    let showsNotificationBadge: Bool
    let isLoading: Bool
    let isPinned: Bool

    init(
        id: TabID = TabID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = nil,
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
    }

    internal init(from tabItem: PaperTabItem) {
        self.id = TabID(id: tabItem.id)
        self.title = tabItem.title
        self.hasCustomTitle = tabItem.hasCustomTitle
        self.icon = tabItem.icon
        self.iconImageData = tabItem.iconImageData
        self.kind = tabItem.kind
        self.isDirty = tabItem.isDirty
        self.showsNotificationBadge = tabItem.showsNotificationBadge
        self.isLoading = tabItem.isLoading
        self.isPinned = tabItem.isPinned
    }
}

// MARK: - Navigation Direction

enum NavigationDirection: Sendable {
    case left
    case right
    case up
    case down
}

// MARK: - Split Orientation

enum SplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical
}

// MARK: - Pixel Coordinates

struct PixelRect: Codable, Sendable, Equatable {
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

// MARK: - Pane Geometry

struct PaneGeometry: Codable, Sendable, Equatable {
    let paneId: String
    let frame: PixelRect
    let selectedTabId: String?
    let tabIds: [String]

    init(paneId: String, frame: PixelRect, selectedTabId: String?, tabIds: [String]) {
        self.paneId = paneId
        self.frame = frame
        self.selectedTabId = selectedTabId
        self.tabIds = tabIds
    }
}

// MARK: - Layout Snapshot

struct LayoutSnapshot: Codable, Sendable, Equatable {
    let containerFrame: PixelRect
    let panes: [PaneGeometry]
    let focusedPaneId: String?
    let timestamp: TimeInterval

    init(containerFrame: PixelRect, panes: [PaneGeometry], focusedPaneId: String?, timestamp: TimeInterval) {
        self.containerFrame = containerFrame
        self.panes = panes
        self.focusedPaneId = focusedPaneId
        self.timestamp = timestamp
    }
}

// MARK: - External Tree Representation

struct ExternalTab: Codable, Sendable, Equatable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

struct ExternalPaneNode: Codable, Sendable, Equatable {
    let id: String
    let frame: PixelRect
    let tabs: [ExternalTab]
    let selectedTabId: String?

    init(id: String, frame: PixelRect, tabs: [ExternalTab], selectedTabId: String?) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.selectedTabId = selectedTabId
    }
}

struct ExternalSplitNode: Codable, Sendable, Equatable {
    let id: String
    let orientation: String
    let dividerPosition: Double
    let first: ExternalTreeNode
    let second: ExternalTreeNode

    init(id: String, orientation: String, dividerPosition: Double, first: ExternalTreeNode, second: ExternalTreeNode) {
        self.id = id
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}

indirect enum ExternalTreeNode: Codable, Sendable, Equatable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

// MARK: - Tab Context Action

enum TabContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
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

// MARK: - Tab Item (internal mutable representation)

// UTType declarations for drag-and-drop (deferred to V2)
// extension UTType {
//     static var paperTabItem: UTType { UTType(exportedAs: "com.manaflow.cmux.papertabitem") }
//     static var paperTabTransfer: UTType { UTType(exportedAs: "com.manaflow.cmux.papertabtransfer", conformingTo: .data) }
// }

struct PaperTabItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    var icon: String?
    var iconImageData: Data?
    var kind: String?
    var isDirty: Bool
    var showsNotificationBadge: Bool
    var isLoading: Bool
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PaperTabItem, rhs: PaperTabItem) -> Bool {
        lhs.id == rhs.id
    }

    enum CodingKeys: String, CodingKey {
        case id, title, hasCustomTitle, icon, iconImageData, kind, isDirty
        case showsNotificationBadge, isLoading, isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        hasCustomTitle = try container.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        iconImageData = try container.decodeIfPresent(Data.self, forKey: .iconImageData)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        isDirty = try container.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        showsNotificationBadge = try container.decodeIfPresent(Bool.self, forKey: .showsNotificationBadge) ?? false
        isLoading = try container.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

// Transferable conformance deferred to V2 (requires Info.plist UTType declarations)
// extension PaperTabItem: Transferable { ... }

struct PaperTabTransferData: Codable {
    let tab: PaperTabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    init(tab: PaperTabItem, sourcePaneId: UUID, sourceProcessId: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }
}

// MARK: - Content View Lifecycle

enum ContentViewLifecycle: Sendable {
    case recreateOnSwitch
    case keepAllAlive
}

// MARK: - New Tab Position

enum NewTabPosition: Sendable {
    case current
    case end
}

// MARK: - Context Menu Shortcuts

struct ContextMenuShortcuts: Sendable {
    var closeTab: KeyEquivalent?
    var closeTabModifiers: EventModifiers
    var newTerminal: KeyEquivalent?
    var newTerminalModifiers: EventModifiers
    var renameTab: KeyEquivalent?
    var renameTabModifiers: EventModifiers
    var togglePin: KeyEquivalent?
    var togglePinModifiers: EventModifiers

    init(
        closeTab: KeyEquivalent? = nil,
        closeTabModifiers: EventModifiers = [],
        newTerminal: KeyEquivalent? = nil,
        newTerminalModifiers: EventModifiers = [],
        renameTab: KeyEquivalent? = nil,
        renameTabModifiers: EventModifiers = [],
        togglePin: KeyEquivalent? = nil,
        togglePinModifiers: EventModifiers = []
    ) {
        self.closeTab = closeTab
        self.closeTabModifiers = closeTabModifiers
        self.newTerminal = newTerminal
        self.newTerminalModifiers = newTerminalModifiers
        self.renameTab = renameTab
        self.renameTabModifiers = renameTabModifiers
        self.togglePin = togglePin
        self.togglePinModifiers = togglePinModifiers
    }
}
