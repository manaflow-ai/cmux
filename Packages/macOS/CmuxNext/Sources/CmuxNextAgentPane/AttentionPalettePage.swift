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
    public let tabs: AgentPaneAttentionTabs

    public init(tabs: AgentPaneAttentionTabs) {
        self.tabs = tabs
    }

    public static let id: ActionID = "attention.goTo"
    /// The page's `PalettePageSpec.id`.
    public static let pageID = "attention"

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
