import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextHome

/// The panels the Home transcript header's top-right toggles open and close beside Home, like
/// Claude desktop's panel buttons (Leo 2026-10-20: "stop opening the hard-coded default right
/// pane. Use top-right toggle buttons ... Nothing opens by default"). Each toggle is one entry of
/// ``HomeHeaderPanels/all``: an action the click runs (the palette and the keyboard run the same
/// one), and an observable read of whether its panel is open, which lights the button.
///
/// Adding a panel is one entry: e.g. a Chief views gallery is
/// `HomeHeaderPanel(id: "views", symbol: "square.grid.2x2", label: { … }, action: "chief.toggleViews",
/// isOpen: { $0.services.pageIsOpen(.chiefViews) })`, with its toggle action in the catalog.
@MainActor
struct HomeHeaderPanel {
    /// Stable id (the button's `cmux.home.headerPanel.<id>` accessibility identifier).
    let id: String
    let symbol: String
    var onSymbol: String?
    /// The localized name (VoiceOver label and tooltip).
    let label: @MainActor () -> String
    /// What a click runs, with ``arguments``; its shortcut shows in the tooltip.
    let action: ActionID
    /// Whether the toggle shows for this conversation (Memory: a Chief's only).
    var isShown: @MainActor (HomeHeaderPanelContext) -> Bool = { _ in true }
    /// Shown even while Debug Settings > Home > Home header panel toggles is off: a control that is
    /// also an indicator the person must always see (Share Screen with Chief).
    var alwaysShown = false
    /// The click's arguments (Memory names this conversation's Chief).
    var arguments: @MainActor (HomeHeaderPanelContext) -> [String: ActionValue] = { _ in [:] }
    /// The panel is open in the context's window. Read inside an observation, so it must read
    /// observable state only (the tree, window state, models), never poll.
    let isOpen: @MainActor (HomeHeaderPanelContext) -> Bool
}

/// What a header toggle reads: the app, the window showing this Home, and its conversation.
@MainActor
struct HomeHeaderPanelContext {
    let services: AppServices
    let window: WindowController?
    /// The conversation is a Chief's.
    let isChief: Bool
    /// The Chief's routing (``ChiefInspectorHandlers/route(_:)``): a named local Chief, or a paired server's.
    let chief: String?
    let server: String?
}

@MainActor
enum HomeHeaderPanels {
    /// Every header toggle, left to right.
    static let all: [HomeHeaderPanel] = [screenShare, memory, rightSidebar]

    /// Share Screen with Chief (docs/chief-screen-share.md): on this Mac's own Chief only, lit while
    /// the Chief can see the screen; a click starts or stops sharing.
    static let screenShare = HomeHeaderPanel(
        id: "screenShare", symbol: "display", onSymbol: "record.circle", label: { ChiefScreenShareActions.headerLabel },
        action: ChiefScreenShareActions.toggleID,
        isShown: { $0.isChief && $0.chief == nil && $0.server == nil },
        alwaysShown: true,
        isOpen: { $0.services.chiefScreenShare.isOn })

    /// The Chief's Memory Inspector, a tab in Home's right column (``ChiefMemoryPageService``).
    static let memory = HomeHeaderPanel(
        id: "memory", symbol: "brain", label: { HomeHeaderPanelStrings.memory },
        action: ChiefInspectorHandlers.toggleActionID,
        isShown: { $0.isChief },
        arguments: { context in
            if let server = context.server { return ["server": .string(server)] }
            if let chief = context.chief { return ["chief": .string(chief)] }
            return [:]
        },
        isOpen: { context in
            guard let window = context.window,
                  let memory = context.services.pages.provider(.chiefMemory) as? ChiefMemoryPageService else { return false }
            return memory.isShown(in: window)
        })

    /// The window's right sidebar (Sessions, Files, Feed, Dock, Machines): its own toggle action.
    static let rightSidebar = HomeHeaderPanel(
        id: "rightSidebar", symbol: "sidebar.right", label: { HomeHeaderPanelStrings.rightSidebar },
        action: "toggleRightSidebar",
        isOpen: { $0.window?.rightSidebar.isVisible ?? false })

    /// The cluster's buttons for `context` (only the ``HomeHeaderPanel/alwaysShown`` ones while Debug
    /// Settings > Home > Home header panel toggles is off): an observable read, so a watch redraws them when any panel opens or closes.
    static func items(_ context: HomeHeaderPanelContext, panels: [HomeHeaderPanel] = all,
                      enabled: Bool = HomeTunables.headerPanelToggles.value) -> [HomeHeaderPanelItem] {
        let registry = context.services.registry
        return panels.filter { (enabled || $0.alwaysShown) && $0.isShown(context) }.map { panel in
            HomeHeaderPanelItem(id: panel.id, symbol: panel.symbol, onSymbol: panel.onSymbol, label: panel.label(),
                                shortcut: registry.shortcutDisplay(for: panel.action), isOn: panel.isOpen(context))
        }
    }

    /// A click on toggle `id`: its action, as the person's own run.
    @discardableResult
    static func toggle(_ id: String, _ context: HomeHeaderPanelContext, panels: [HomeHeaderPanel] = all) -> Bool {
        guard let panel = panels.first(where: { $0.id == id }) else { return false }
        return context.services.registry.perform(panel.action, invocation: ActionInvocation(arguments: panel.arguments(context), origin: .user))
    }
}

enum HomeHeaderPanelStrings {
    static var memory: String {
        String(localized: "home.headerPanels.memory", defaultValue: "Memory Inspector", table: "MiscHandlers", bundle: .module)
    }
    static var rightSidebar: String {
        String(localized: "home.headerPanels.rightSidebar", defaultValue: "Right Sidebar", table: "MiscHandlers", bundle: .module)
    }
}
