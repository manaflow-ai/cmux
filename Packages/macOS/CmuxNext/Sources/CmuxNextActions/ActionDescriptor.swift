import AppKit

/// A shortcut that stands for a numbered family, such as Cmd-1 to Cmd-9.
public enum ShortcutFamily: Sendable, Hashable {
    /// The digit keys 1 to 9 with the descriptor's modifiers. The pressed
    /// digit is passed to the action's argument handler.
    case digits
}

/// Declarative description of one user-invocable action (the action
/// contract in plans/cmux-next/REWRITE.md). The catalog holds every
/// descriptor; the App binds one handler per ID. Every entrypoint is
/// generated from it: palette row (arguments collected inline from
/// `arguments`), key binding (`defaultShortcut`, user-overridable by `id`),
/// right-click menus (`ContextMenuCatalog`), main menu (`mainMenu`), and the
/// CLI verb (`cliName`).
public struct ActionDescriptor: Identifiable, Sendable {
    public let id: ActionID
    public var title: String
    public var keywords: [String]
    public var defaultShortcut: Shortcut?
    /// Display text for shortcuts a `Shortcut` cannot express, such as the
    /// vim sequence `g g`. Takes precedence over the formatted shortcut.
    public var shortcutLabel: String?
    public var shortcutFamily: ShortcutFamily?
    public var category: ActionCategory
    /// SF Symbol name.
    public var symbol: String
    /// Where the old app exposed the action (inventory legend). Historical;
    /// under the action contract every action reaches every entrypoint.
    public var surfaces: ActionSurfaces
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
        startsTerminal: Bool = false
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
    }

    /// Whether the palette lists the action. Everything is listed except
    /// palette-internal navigation (actions that require the palette open).
    public var isPaletteVisible: Bool { !requires.contains(.paletteOpen) }

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
