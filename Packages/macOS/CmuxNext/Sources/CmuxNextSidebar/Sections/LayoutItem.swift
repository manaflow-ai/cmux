import Foundation

/// Destinations defined in code. Each is a launcher for a registry action
/// (the App maps them); the sidebar only knows the symbol and title.
public nonisolated enum SidebarBuiltIn: String, Hashable, Sendable, CaseIterable {
    case home
    case settings
    case account
    case notifications
    case history
    case bookmarks
}

/// What an item points at: a kind and a string value. Kinds this client
/// does not know are kept verbatim (L5).
public nonisolated struct LayoutItemRef: Hashable, Sendable, Codable {
    public var kind: String
    public var value: String

    public init(kind: String, value: String) {
        self.kind = kind
        self.value = value
    }

    public static let builtInKind = "built_in"
    public static let workspaceKind = "workspace"
    public static let tabKind = "tab"
    public static let roomKind = "room"
    public static let savedGroupKind = "saved_group"
    public static let urlKind = "url"

    public static func builtIn(_ item: SidebarBuiltIn) -> LayoutItemRef { LayoutItemRef(kind: builtInKind, value: item.rawValue) }
    /// A qualified public workspace id (`<session>:ws_…`).
    public static func workspace(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: workspaceKind, value: id) }
    /// A qualified public tab id (`<session>:tab_…`).
    public static func tab(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: tabKind, value: id) }
    public static func room(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: roomKind, value: id) }
    public static func savedGroup(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: savedGroupKind, value: id) }
    public static func url(_ url: String) -> LayoutItemRef { LayoutItemRef(kind: urlKind, value: url) }

    /// The built-in this ref names, or nil (another kind, or a built-in
    /// from a newer client).
    public var builtIn: SidebarBuiltIn? { kind == Self.builtInKind ? SidebarBuiltIn(rawValue: value) : nil }
}

public nonisolated struct LayoutItem: Hashable, Sendable, Codable, Identifiable {
    public var id: LayoutItemID
    public var ref: LayoutItemRef

    public init(id: LayoutItemID, ref: LayoutItemRef) {
        self.id = id
        self.ref = ref
    }
}
