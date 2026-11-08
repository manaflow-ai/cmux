public import CmuxNextActions
public import CmuxNextPalette
import Foundation

/// Go to What Needs Me (`attention.goTo`): the command palette's page of the tabs an agent marked as
/// needing the person (`tab-attention-v1`, `cmux attention request`), newest first. Each row says
/// what to do there (the agent's reason), then the workspace and tab by the titles the person knows
/// them by, never an id; Return shows the tab as Search Tabs does. Leo, 2026-10-22: "idk where
/// things are man i dont see anything other than the current workspace".
@MainActor
public struct AttentionPalettePage {
    /// The marked tabs and their one jump, shared with every agent page's Needs you list.
    public var tabs: AgentPaneAttentionTabs

    public init(tabs: AgentPaneAttentionTabs) { self.tabs = tabs }

    public static let id: ActionID = "attention.goTo"
    /// The page's `PalettePageSpec.id`.
    public static let pageID = "attention"

    public static var needsFocus: String { AttentionPaletteStrings.needsFocus }
    public static var nothing: String { AttentionPaletteStrings.nothing }

    public func page() -> PalettePageSpec {
        PalettePageSpec(id: Self.pageID, title: AttentionPaletteStrings.title, placeholder: AttentionPaletteStrings.placeholder,
                        symbol: "hand.raised", providers: [AttentionPaletteProvider(page: self)])
    }

    /// The rows, read from the marked tabs now.
    public func rows() -> [PaletteItem] {
        let formatter = RelativeDateTimeFormatter()
        return tabs.items.map { item in
            PaletteItem(
                id: "attention:\(item.tabId)", title: item.reason,
                subtitle: [item.workspaceTitle, item.tabTitle].filter { !$0.isEmpty }.joined(separator: " · "),
                accessory: item.atMs > 0 ? formatter.localizedString(for: Date(timeIntervalSince1970: Double(item.atMs) / 1000), relativeTo: Date()) : nil,
                symbol: "hand.raised", keywords: [item.workspaceTitle, item.tabTitle],
                primary: PaletteCommand(id: "open", title: AttentionPaletteStrings.open, symbol: "return",
                                        effect: .perform { [tabs] in _ = tabs.open(item.tabId) }))
        }
    }
}

/// Go to What Needs Me's rows, read from the marked tabs at each load (open, and each reload on a
/// change), never a list taken when the page opened.
final class AttentionPaletteProvider: PaletteProvider {
    let id = AttentionPalettePage.pageID
    private let page: AttentionPalettePage

    init(page: AttentionPalettePage) {
        self.page = page
    }

    // A palette reset can release a provider off the main actor (TabPaletteProvider, #17590).
    nonisolated deinit {}

    var immediateItems: [PaletteItem]? { page.rows() }
    func items() async -> [PaletteItem] { page.rows() }
}

/// Text of the Go to What Needs Me page. Keys live in Resources/MiscHandlers.xcstrings.
struct AttentionPaletteStrings {
    static var title: String { String(localized: "handlers.attention.title", defaultValue: "What Needs You", table: "AttentionTabs", bundle: .module) }
    static var placeholder: String { String(localized: "handlers.attention.placeholder", defaultValue: "Search what needs you", table: "AttentionTabs", bundle: .module) }
    static var open: String { String(localized: "handlers.attention.open", defaultValue: "Go to Tab", table: "AttentionTabs", bundle: .module) }
    static var needsFocus: String {
        String(localized: "handlers.attention.needsFocus",
               defaultValue: "Go to What Needs Me opens only when focus is requested; read the marked tabs with tab.list",
               table: "AttentionTabs", bundle: .module)
    }
    static var nothing: String { String(localized: "handlers.attention.nothing", defaultValue: "No agent needs you in a tab right now.", table: "AttentionTabs", bundle: .module) }
}
