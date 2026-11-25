public import CmuxNextActions
public import CmuxNextPalette

/// The palette's Open In page (Open Current Directory, `palette.terminalOpenDirectory`): the installed editors,
/// the default first, then Finder and a terminal, for the focused tab's folder on this Mac (a terminal's folder,
/// else the agent chat's). Each row runs the action the menus run for that tab: a terminal's Open Current
/// Directory with the row's `app`, a chat's Open In, Reveal in Finder or Open Terminal Here.
public final class EditorOpenInSource: PaletteOpenInSource {
    /// The focused tab on this Mac: its folder (nil when it has none) and whether it is an agent chat; nil when
    /// no pane is focused.
    public struct Focus {
        public var folder: String?
        public var chat: Bool
        public init(folder: String?, chat: Bool) {
            self.folder = folder
            self.chat = chat
        }
    }

    public static let finder = "finder"
    public static let terminal = "terminal"

    private let catalog: EditorCatalog
    private let focus: @MainActor () -> Focus?
    private let perform: @MainActor (ActionID, [String: ActionValue]) -> Void

    /// `perform` runs a row's action as the person's own run, or refuses when `focus` found no pane.
    public init(catalog: EditorCatalog, focus: @escaping @MainActor () -> Focus?, perform: @escaping @MainActor (ActionID, [String: ActionValue]) -> Void) {
        self.catalog = catalog
        self.focus = focus
        self.perform = perform
    }

    public var apps: [PaletteOpenInApp] {
        catalog.detected().ordered.map { PaletteOpenInApp(id: $0.id, name: $0.name, symbol: $0.editor.symbol) } + [
            PaletteOpenInApp(id: Self.finder, name: EditorStrings.finder, symbol: "folder"),
            PaletteOpenInApp(id: Self.terminal, name: EditorStrings.terminal, symbol: "terminal"),
        ]
    }

    public var currentDirectory: String? { focus()?.folder }

    public func open(appID: String) {
        let (id, arguments) = Self.route(appID, chat: focus()?.chat ?? false)
        perform(id, arguments)
    }

    /// The action and arguments a row runs: on a chat its folder actions, else the terminal's Open Current Directory.
    public static func route(_ appID: String, chat: Bool) -> (ActionID, [String: ActionValue]) {
        guard chat else { return ("palette.terminalOpenDirectory", ["app": .string(appID)]) }
        switch appID {
        case finder: return ("agentPane.revealCwdInFinder", [:])
        case terminal: return ("agentPane.openCwdInTerminal", [:])
        default: return ("agentPane.openCwdInApp", ["app": .string(appID)])
        }
    }
}
