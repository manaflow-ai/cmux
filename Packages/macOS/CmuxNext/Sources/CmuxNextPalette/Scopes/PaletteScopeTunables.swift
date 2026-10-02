public import CmuxNextDesign

/// How the current scope shows (`palette.scopeChip`, DEV and NIGHTLY).
public nonisolated enum PaletteScopeChipStyle: String, Sendable, CaseIterable, TunableChoice {
    /// A gray capsule with the scope's icon and title inside the field,
    /// before the caret; the level below shows as a dimmer capsule.
    case token
    /// A small path above the field ("Commands › Tabs").
    case breadcrumb
    /// The scope's icon and title replace the magnifier, in semibold.
    case header

    public var tunableTitle: String {
        switch self {
        case .token: "Token (capsule in the field)"
        case .breadcrumb: "Breadcrumb (path above the field)"
        case .header: "Header (icon and title before the field)"
        }
    }
}

/// Which gestures enter a scope (`palette.scopeEntry`, DEV and NIGHTLY).
public nonisolated enum PaletteScopeEntryStyle: String, Sendable, CaseIterable, TunableChoice {
    /// Prefixes, keyword plus Tab, prefix hints in the footer, and scope
    /// rows when the query names a scope.
    case all
    /// Only prefixes (`@` Tabs), with prefix hints in the footer.
    case prefix
    /// Only a keyword plus Tab ("tabs" Tab), with a hint in the field.
    case keyword
    /// Only scope rows: a Search In section above the empty root list.
    case list

    public var tunableTitle: String {
        switch self {
        case .all: "All (prefix, keyword + Tab, scope rows)"
        case .prefix: "Prefix only (@ Tabs, # Workspaces)"
        case .keyword: "Keyword + Tab only (tabs ⇥)"
        case .list: "Scope list only (Search In section)"
        }
    }

    public var prefixEntry: Bool { self == .all || self == .prefix }
    public var keywordEntry: Bool { self == .all || self == .keyword }
    /// Scope rows appear in the empty root list.
    public var listsScopesWhenEmpty: Bool { self == .list }
    /// Scope rows appear in the root once the user types.
    public var listsScopesWhenTyping: Bool { self == .all || self == .list }
    /// The footer shows prefix hints on the empty root.
    public var showsPrefixHints: Bool { self == .all || self == .prefix }
}

/// Debug Settings declarations of palette scopes.
public nonisolated enum PaletteScopeTunables {
    public static let chipStyle = Tunable<PaletteScopeChipStyle>.choice(
        "palette.scopeChip", .palette, "Scope chip",
        help: "Prototype look of the current palette scope. Applies the next time the palette opens.",
        default: .token, code: "PaletteScopeTunables.chipStyle")

    public static let entryStyle = Tunable<PaletteScopeEntryStyle>.choice(
        "palette.scopeEntry", .palette, "Scope entry",
        help: "Prototype gestures that enter a palette scope. Applies the next time the palette opens.",
        default: .all, code: "PaletteScopeTunables.entryStyle")

    public static let itemActions = Tunable<PaletteItemActionsStyle>.choice(
        "palette.itemActions", .palette, "Tab on a row",
        help: "Prototype: Tab on a row opens the Actions menu, or its actions as a scope.",
        default: .menu, code: "PaletteScopeTunables.itemActions")

    public static var all: [TunableDescriptor] { [chipStyle.descriptor, entryStyle.descriptor, itemActions.descriptor] }
}
