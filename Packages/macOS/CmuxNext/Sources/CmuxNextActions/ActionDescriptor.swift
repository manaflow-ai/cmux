import AppKit

/// A shortcut that stands for a numbered family, such as Cmd-1 to Cmd-9.
public nonisolated enum ShortcutFamily: Sendable, Hashable {
    /// The digit keys 1 to 9 with the descriptor's modifiers. The pressed
    /// digit is passed to the action's argument handler.
    case digits
}

/// Declarative description of one user-invocable action (the action
/// contract in plans/cmux-next/REWRITE.md). The catalog holds every
/// descriptor; the App binds one handler per ID. Every entrypoint is
/// generated from it: palette row (arguments collected inline from
/// `arguments`), key binding (`defaultShortcut`, user-overridable by `id`),
/// right-click menus (`ContextMenuCatalog`, from `surfacePlan` placements),
/// main menu (`mainMenu`), and the CLI verb (`cliName`). `surfacePlan`
/// declares which surfaces offer the action, or why one does not.
public nonisolated struct ActionDescriptor: Identifiable, Sendable {
    public let id: ActionID
    public var title: String
    public var keywords: [String]
    public var defaultShortcut: Shortcut?
    /// Display text for shortcuts a `Shortcut` cannot express, such as the
    /// vim sequence `g g`. Takes precedence over the formatted shortcut.
    public var shortcutLabel: String?
    public var shortcutFamily: ShortcutFamily?
    /// A two-key default (`LeaderLayer`: Cmd-J then a key), in addition to
    /// `defaultShortcut`. cmux.json replaces it with a chord, and a single
    /// key or an unbind there drops it (`ActionRegistry.effectiveChord`).
    public var defaultChord: ShortcutChord?
    public var category: ActionCategory
    /// SF Symbol name.
    public var symbol: String
    /// Where the old app exposed the action (inventory legend). Historical;
    /// `surfacePlan` is the declaration the registry and tests use.
    public var surfaces: ActionSurfaces
    /// Which surfaces offer the action, with a reason for each that does
    /// not (plans/cmux-next/actions.md). Palette, CLI verb, right-click
    /// placements and MCP; the keyboard binds every action by `id`.
    public var surfacePlan: ActionSurfacePlan
    /// Availability predicate: context facts that must all be present.
    public var requires: ActionContext
    /// Typed argument schema, collected in order.
    public var arguments: [ActionArgument]
    /// Kinds of object the action operates on. Nil target at run time means
    /// the focused object of the first kind; a right-click or `--target`
    /// passes one explicitly.
    public var targets: [ActionTargetKind]
    /// Friendly CLI verb, `noun verb` (`tab-group create`). Unique.
    public var cliName: String
    /// Main menu the action appears in, if any.
    public var mainMenu: ActionMainMenu?
    /// A developer tool: available in DEV and NIGHTLY builds only, absent
    /// from every surface in Release and RC (`DevTools`).
    public var isDebugOnly: Bool
    /// Deletes or closes something the user cannot get back (a Cloud
    /// machine, a workspace group, a workspace with running processes, a
    /// tab group). The schema gains an optional bool `confirm` argument.
    /// Keyboard, menu, and palette runs ask the registry's
    /// `confirmationPresenter` first; a scripted run must pass
    /// `confirm: true` (CLI `--confirm`) or is refused.
    public var isDestructive: Bool
    /// Starts a terminal: its work waits for cmux-tui to launch a terminal
    /// host, so a caller that awaits it (`action.run` with `wait`, the CLI
    /// compat layer) uses the terminal start deadline instead of the
    /// control-plane one.
    public var startsTerminal: Bool
    /// Has a purpose outside the GUI (creating, closing, renaming, moving or
    /// pinning objects; opening a page; headless settings; scriptable agent
    /// and Cloud work), so the `cmux` CLI offers it by `cliName`. GUI-only
    /// actions (focus moves, palette navigation, zoom) stay reachable by id
    /// through `cmux action run` (plans/cmux-next/state-ownership.md 5).
    /// `surfacePlan.cli` decides it (`ActionSurfaceCatalog.cliNamed`).
    public var cli: Bool { surfacePlan.cli?.isOffered == true }
    /// The action's work is a network round trip whose outcome the caller
    /// needs (Connect to CodeRouter): the CLI runs it with `wait` and the
    /// control socket gives it ``ActionDescriptor/resultDeadline``.
    public var waitsForResult: Bool = false
    /// The action's purpose is to change this client's view: focus a pane
    /// or tab, select a tab, show a workspace, bring a window forward
    /// (tab.focus, Go to Tab, workspace next/previous, pane focus moves).
    /// Such a run may change the view whatever its origin; any other run
    /// only when its origin is the user or it asks with `focus: true`
    /// (plans/cmux-next/OWNERSHIP-PRINCIPLES.md, ``ActionRunScope``).
    /// The catalog marks these in `ActionCatalog.focusActionIDs`.
    public var focuses: Bool = false
    /// Only a person in the app runs it (palette, menu, keyboard): the
    /// control socket refuses it whatever origin the caller claims, so no
    /// script or agent can start it (Import Passwords from CSV).
    public var isPersonOnly: Bool = false
    /// Registered system-wide (a Carbon hot key) with its effective
    /// shortcut, so it runs while another app is frontmost. The App's
    /// `GlobalHotKeyService` owns registration and follows rebinds.
    public var isGlobalHotKey: Bool = false
    /// How long `action.run` with `wait` may take for such an action.
    public static let resultDeadline: Duration = .seconds(40)

    public init(
        id: ActionID,
        title: String,
        keywords: [String] = [],
        defaultShortcut: Shortcut? = nil,
        shortcutLabel: String? = nil,
        shortcutFamily: ShortcutFamily? = nil,
        category: ActionCategory,
        symbol: String = "command",
        surfaces: ActionSurfaces = [.palette],
        requires: ActionContext = [],
        arguments: [ActionArgument] = [],
        targets: [ActionTargetKind] = [],
        cliName: String? = nil,
        mainMenu: ActionMainMenu? = nil,
        isDebugOnly: Bool = false,
        destructive: Bool = false,
        startsTerminal: Bool = false,
        surfacePlan: ActionSurfacePlan = ActionSurfacePlan()
    ) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.defaultShortcut = defaultShortcut
        self.shortcutLabel = shortcutLabel
        self.shortcutFamily = shortcutFamily
        self.category = category
        self.symbol = symbol
        self.surfaces = surfaces
        self.requires = requires
        self.arguments = arguments
        if destructive, !arguments.contains(where: { $0.name == ActionArgument.confirmName }) {
            self.arguments.append(CatalogArgument.confirmBool)
        }
        self.isDestructive = destructive
        self.startsTerminal = startsTerminal
        self.targets = targets
        self.cliName = cliName ?? Self.defaultCLIName(for: id)
        self.mainMenu = mainMenu
        self.isDebugOnly = isDebugOnly
        self.surfacePlan = surfacePlan
        if requires.contains(.paletteOpen) { self.surfacePlan.palette = .exempt(.paletteInternal) }
    }

    /// Whether the palette lists the action (`surfacePlan.palette`).
    /// Everything is listed except palette-internal navigation.
    public var isPaletteVisible: Bool { surfacePlan.palette.isOffered }

    /// CLI verb for actions registered without one: `action <kebab-id>`.
    public static func defaultCLIName(for id: ActionID) -> String {
        var result = ""
        for character in id.rawValue {
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else if character == "." || character == "_" {
                result += "-"
            } else {
                result.append(character)
            }
        }
        return "action " + result
    }
}
