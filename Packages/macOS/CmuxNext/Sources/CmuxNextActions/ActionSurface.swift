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
    /// The App binds it as unavailable in every build today (no handler
    /// yet); offer it when it works.
    case unimplemented
    /// The browser engine that is not the default (WebKit; Chrome is the
    /// default): reachable from the palette, the CLI and MCP, never from a
    /// menu (Lawrence, 2026-10-01).
    case secondaryEngine
    /// The same action as the default one the surface already offers
    /// (New Browser Tab on Chrome next to New Browser Tab on the default
    /// engine).
    case duplicateOfDefault
    /// Sign-in, accounts and secrets: a person does it (MCP).
    case credentials
    /// Quits the app the user works in (MCP).
    case endsApp
    /// Changes preferences, the system or the running app outside the
    /// user's work (MCP).
    case systemChange
    /// The object's owner already offers the same verb under this CLI name
    /// (the daemon's `room create` for Rooms); the app action is its GUI
    /// form, and the CLI runs the owner's operation.
    case ownerVerb
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
