/// Where an action can be invoked from (plans/cmux-next/actions.md). The
/// user rule: every action is reachable from the CLI, a right-click menu and
/// the command palette where that makes sense; where it does not, the action
/// says why with an ``SurfaceExemption``. `ActionSurfaceParityTests` checks
/// every action against every surface.
public nonisolated enum ActionSurface: String, CaseIterable, Sendable, Hashable, Codable {
    /// The command palette (Cmd-Shift-P).
    case palette
    /// A `cmux <noun> <verb>` verb (`ActionDescriptor.cliName`). Every action
    /// also runs by id with `cmux action run`; this surface is the named verb.
    case cli
    /// At least one right-click menu (`ContextMenuCatalog`, generated from
    /// placements).
    case contextMenu
    /// A tool of `cmux mcp serve`. Follows the CLI unless exempt.
    case mcp
}

/// Why an action is not offered on a surface. Every omission names one;
/// there is no silent omission.
public nonisolated enum SurfaceExemption: String, CaseIterable, Sendable, Hashable, Codable {
    /// Operates the palette itself (next or previous row).
    case paletteInternal
    /// Exists only in debug builds.
    case devOnly
    /// Moves focus or selection between existing objects, or shows one
    /// (next tab, focus left, select workspace 3). The click on the object
    /// is the gesture, and view state belongs to each client, so a script
    /// reaches it only by id (`cmux action run`).
    case focusMove
    /// One step of a repeated adjustment (zoom, font size, resize by a
    /// step, scroll a page). A key or palette repeat, not a menu row or verb.
    case stepAdjust
    /// Acts on live input focus: the focused text field, the selection, the
    /// find bar, copy mode, the text box, or a selected row in a panel.
    case liveInput
    /// Opens, shows or toggles a piece of app UI (a window, panel, sheet,
    /// bubble, editor). Nothing to script.
    case guiOnly
    /// Copies to the pasteboard. The CLI prints the same value
    /// (`cmux tab list --json`).
    case clipboard
    /// App-wide: there is no object to right-click.
    case noObject
    /// The object it acts on has no right-click surface yet (diff viewer,
    /// file preview, simulator, canvas, saved groups, VS Code pane). A gap
    /// to close when that surface gets a menu.
    case noTargetSurface
    /// A value of a family that another action offers (Set Color > Blue,
    /// Collapse/Expand under Toggle Collapsed, the engine-specific browser
    /// entries for Open Browser, a cycle that a direct setter covers).
    case familyMember
    /// The gesture is a drag (reorder to an index); the menu offers the
    /// discrete moves.
    case dragGesture
    /// Sign-in, accounts and secrets: a person does it (MCP).
    case credentials
    /// Quits the app the user works in (MCP).
    case endsApp
    /// Changes preferences, the system or the running app outside the
    /// user's work (MCP).
    case systemChange
}

/// A surface decision: offered, or exempt with a reason.
public nonisolated enum SurfaceDecision: Sendable, Hashable {
    case offered
    case exempt(SurfaceExemption)

    public var isOffered: Bool { self == .offered }

    public var exemption: SurfaceExemption? {
        if case .exempt(let reason) = self { reason } else { nil }
    }

    /// Wire form for `action.list`: `"offered"` or the exemption's raw value.
    public var wireValue: String { exemption?.rawValue ?? "offered" }
}

/// Semantic group of a right-click menu row. Menus list groups in this
/// order with a separator between them, so a new action lands in the right
/// area of every menu by naming its group.
public nonisolated enum MenuGroup: Int, CaseIterable, Sendable, Hashable, Comparable {
    /// Copy, paste, select all, use selection.
    case edit
    /// Back, forward, reload, open a link or a row.
    case navigate
    /// New, duplicate, split, open a kind of tab.
    case create
    /// Reopen in another engine or profile.
    case reopen
    /// Rename, color, icon, pin, read state, theme, status, defaults.
    case identity
    /// Group membership, saved groups, collapse.
    case organize
    /// Move or reorder to another place.
    case move
    /// Size, zoom, equalize, sticky.
    case layout
    /// Reconnect, disconnect, hibernate, swap a session.
    case connection
    /// Resources, IDs, links, page info, developer tools, screenshots.
    case inspect
    /// Show or hide chrome (sidebar, bookmarks bar).
    case view
    /// Clear or reset content.
    case reset
    /// Close, delete, forget, ungroup.
    case close

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// How a placement renders.
public nonisolated enum MenuPlacementStyle: Sendable, Hashable {
    /// One menu item.
    case item
    /// A submenu with one item per value of the action's first enumeration
    /// argument (``ContextMenuEntry/choices(_:)``).
    case choices
    /// A submenu titled by the action whose children are the placements in
    /// the same context that name this action as their `parent`.
    case submenu
}

/// One row of one right-click menu, declared by the action.
public nonisolated struct ContextMenuPlacement: Sendable, Hashable {
    public var context: ActionMenuContext
    public var group: MenuGroup
    /// Order inside the group. Ranks in different hundreds are separate
    /// sections of the group (a separator between them).
    public var rank: Int
    public var style: MenuPlacementStyle
    /// The submenu anchor this row belongs to, if any.
    public var parent: ActionID?

    public init(_ context: ActionMenuContext, _ group: MenuGroup, _ rank: Int = 0,
                style: MenuPlacementStyle = .item, parent: ActionID? = nil) {
        self.context = context
        self.group = group
        self.rank = rank
        self.style = style
        self.parent = parent
    }
}

/// Every surface decision of one action: the descriptor's declaration of
/// where it can be invoked. The registry generates the palette list, the
/// right-click menus and the CLI verbs from it; all of them call the same
/// `ActionRegistry.perform` path with the caller's origin.
public nonisolated struct ActionSurfacePlan: Sendable, Hashable {
    public var palette: SurfaceDecision
    /// Offered: the CLI has the verb `cliName`. Exempt: only
    /// `cmux action run <id>` reaches it. Nil until declared (the parity
    /// test rejects that).
    public var cli: SurfaceDecision?
    /// The menus the action appears in. Empty requires
    /// `contextMenuExemption`.
    public var contextMenus: [ContextMenuPlacement]
    public var contextMenuExemption: SurfaceExemption?
    /// An MCP-only exemption on top of the CLI decision.
    public var mcpExemption: SurfaceExemption?

    public init(
        palette: SurfaceDecision = .offered,
        cli: SurfaceDecision? = nil,
        contextMenus: [ContextMenuPlacement] = [],
        contextMenuExemption: SurfaceExemption? = nil,
        mcpExemption: SurfaceExemption? = nil
    ) {
        self.palette = palette
        self.cli = cli
        self.contextMenus = contextMenus
        self.contextMenuExemption = contextMenuExemption
        self.mcpExemption = mcpExemption
    }

    /// The right-click decision: offered when placed, else the exemption.
    /// Nil when neither is declared (the parity test rejects that).
    public var contextMenu: SurfaceDecision? {
        if !contextMenus.isEmpty { return .offered }
        return contextMenuExemption.map(SurfaceDecision.exempt)
    }

    /// MCP follows the CLI: a tool exactly when the CLI has the verb and no
    /// MCP exemption applies.
    public var mcp: SurfaceDecision? {
        guard let cli, cli.isOffered else { return cli }
        return mcpExemption.map(SurfaceDecision.exempt) ?? .offered
    }

    /// The decision for `surface`, nil when undeclared.
    public func decision(for surface: ActionSurface) -> SurfaceDecision? {
        switch surface {
        case .palette: palette
        case .cli: cli
        case .contextMenu: contextMenu
        case .mcp: mcp
        }
    }
}
