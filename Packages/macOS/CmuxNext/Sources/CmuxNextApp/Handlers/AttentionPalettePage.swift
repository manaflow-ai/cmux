import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextPalette
import Foundation

/// Go to What Needs Me (`attention.goTo`): the command palette's page of the tabs an agent marked as
/// needing the person (`tab-attention-v1`, `cmux attention request`), newest first. Each row says
/// what to do there (the agent's reason), then the workspace and tab by the titles the person knows
/// them by, never an id; Return shows the tab as Search Tabs does. Leo, 2026-10-22: "idk where
/// things are man i dont see anything other than the current workspace".
@MainActor
struct AttentionPalettePage {
    /// The marked tabs and their one jump, shared with every agent page's Needs you list.
    var tabs: AgentPaneAttentionTabs = .shared

    static let id: ActionID = "attention.goTo"

    /// Binds the action and routes every Go to (this page's and the agent pages') through the
    /// user's jump, ``AppServices/revealTab(_:intent:)``.
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        AgentPaneAttentionTabs.shared.onOpen = { [weak services = context.services] id in services?.revealTab(id) ?? false }
        context.services.palette.sources.actionPages[id] = { AttentionPalettePage().page() }
        registry.bind(id, run: { _ in
            let page = AttentionPalettePage()
            guard !page.tabs.items.isEmpty else { throw ActionFailure(message: AttentionPaletteStrings.nothing) }
            context.services.palette.show(page: page.page(), relativeTo: context.activeWindow?.window)
        })
    }

    func page() -> PalettePageSpec {
        let formatter = RelativeDateTimeFormatter()
        let rows = tabs.items.map { item in
            PaletteItem(
                id: "attention:\(item.tabId)", title: item.reason,
                subtitle: [item.workspaceTitle, item.tabTitle].filter { !$0.isEmpty }.joined(separator: " · "),
                accessory: item.atMs > 0 ? formatter.localizedString(for: Date(timeIntervalSince1970: Double(item.atMs) / 1000), relativeTo: Date()) : nil,
                symbol: "hand.raised", keywords: [item.workspaceTitle, item.tabTitle],
                primary: PaletteCommand(id: "open", title: AttentionPaletteStrings.open, symbol: "return",
                                        effect: .perform { [tabs] in _ = tabs.open(item.tabId) }))
        }
        return PalettePageSpec(id: "attention", title: AttentionPaletteStrings.title, placeholder: AttentionPaletteStrings.placeholder,
                               symbol: "hand.raised", providers: [StaticPaletteProvider(id: "attention", items: rows)])
    }
}

/// Text of the Go to What Needs Me page. Keys live in Resources/MiscHandlers.xcstrings.
struct AttentionPaletteStrings {
    static var title: String { String(localized: "handlers.attention.title", defaultValue: "What Needs You", table: "MiscHandlers", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.attention.placeholder", defaultValue: "Search what needs you", table: "MiscHandlers", bundle: .module) }
    static var open: String { String(localized: "handlers.attention.open", defaultValue: "Go to Tab", table: "MiscHandlers", bundle: .module) }
    static var nothing: String { String(localized: "handlers.attention.nothing", defaultValue: "No agent needs you in a tab right now.", table: "MiscHandlers", bundle: .module) }
}
