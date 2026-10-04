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
    case appStore = "app_store"
    /// New-tab launchers, for sections.
    case newTerminal = "new_terminal"
    case newBrowser = "new_browser"
    case newAgentChat = "new_agent_chat"
    /// The appearance studio (Customize Appearance).
    case customize
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
    /// An installed cmux app (`<publisher>/<name>`); its menu offers Hide.
    public static let appKind = "app"

    public static func builtIn(_ item: SidebarBuiltIn) -> LayoutItemRef { LayoutItemRef(kind: builtInKind, value: item.rawValue) }
    /// A qualified public workspace id (`<session>:ws_…`).
    public static func workspace(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: workspaceKind, value: id) }
    /// A qualified public tab id (`<session>:tab_…`).
    public static func tab(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: tabKind, value: id) }
    public static func room(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: roomKind, value: id) }
    public static func savedGroup(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: savedGroupKind, value: id) }
    public static func url(_ url: String) -> LayoutItemRef { LayoutItemRef(kind: urlKind, value: url) }
    public static func app(_ id: String) -> LayoutItemRef { LayoutItemRef(kind: appKind, value: id) }

    /// The built-in this ref names, or nil (another kind, or a built-in
    /// from a newer client).
    public var builtIn: SidebarBuiltIn? { kind == Self.builtInKind ? SidebarBuiltIn(rawValue: value) : nil }
}

public nonisolated struct LayoutItem: Hashable, Sendable, Codable, Identifiable {
    public var id: LayoutItemID
    public var ref: LayoutItemRef
    /// False: the item shows its icon only on a line (inline arrangement),
    /// like the account avatar beside Settings.
    public var showsLabel: Bool

    /// The app this item opens, for an app item.
    public var owningAppID: String? { ref.kind == LayoutItemRef.appKind ? ref.value : nil }

    public init(id: LayoutItemID, ref: LayoutItemRef, showsLabel: Bool = true) {
        self.id = id
        self.ref = ref
        self.showsLabel = showsLabel
    }

    enum CodingKeys: String, CodingKey {
        case id, ref
        case showsLabel = "shows_label"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LayoutItemID.self, forKey: .id)
        ref = try c.decode(LayoutItemRef.self, forKey: .ref)
        showsLabel = try c.decodeIfPresent(Bool.self, forKey: .showsLabel) ?? true
    }
}
