public import CmuxNextDesign
import Foundation

/// What a workspace row's name says (Debug Settings `sidebar.rowTitle`). Leo 2026-10-26: "Can we
/// say, like, the name of the workspace can kind of be considered the root? ... Your currently
/// focused tab within the workspace. So then you have a workspace name and then you have the tab
/// name, and they can be shown together on the sidebar, potentially." The workspace name stays the
/// default; the other modes are toggles to try.
public nonisolated enum SidebarRowTitleMode: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The workspace name alone (the shipped row).
    case workspace
    /// "Workspace › Focused tab": the workspace is the root, the focused tab follows it.
    case breadcrumb
    /// The focused tab's name alone; the hover card still names the workspace.
    case focusedTab
    /// "Workspace › Focused tab · Other tab · …", cut off at the row's end.
    case allTabs

    public var tunableTitle: String {
        switch self {
        case .workspace: "Workspace only"
        case .breadcrumb: "Workspace › focused tab"
        case .focusedTab: "Focused tab only (workspace on hover)"
        case .allTabs: "Workspace › all tabs"
        }
    }
}

nonisolated extension SidebarRowTitleMode {
    /// Between the workspace (the root) and its tab.
    public static let crumb = " › "
}

/// The name a workspace row draws under `SidebarRowTitleMode`, from the workspace's name, its tabs
/// as the tab list titles them and its focused tab (`focusedTab`).
nonisolated extension SidebarWorkspace {
    /// The row's name. `inheritsSingleChat`: a workspace whose one tab is an agent chat shows the
    /// chat's name alone in every mode (Leo: "either you can just directly inherit the thing if
    /// it's only that one agent chat"). A tab named like the workspace is not repeated: automatic
    /// workspace names follow the focused chat's title (cmux#25416), so "Fix login › Fix login"
    /// would say one name twice.
    public func rowTitle(_ mode: SidebarRowTitleMode, inheritsSingleChat: Bool = false) -> String {
        // A placeholder's empty name draws the loading bar; it gains no crumbs.
        guard !title.isEmpty else { return title }
        if inheritsSingleChat, tabs.count == 1, tabs[0].kind.isChat, let chat = Self.named(tabs[0].title) {
            return chat
        }
        guard mode != .workspace else { return title }
        let focused = focusedTab.flatMap { id in tabs.first { $0.id == id } }
        let tabTitle = focused.flatMap { Self.named($0.title) }.flatMap { Self.same($0, title) ? nil : $0 }
        switch mode {
        case .workspace:
            return title
        case .breadcrumb:
            return tabTitle.map { title + SidebarRowTitleMode.crumb + $0 } ?? title
        case .focusedTab:
            return focused.flatMap { Self.named($0.title) } ?? title
        case .allTabs:
            // The focused tab first, then the others in pane order; the label cuts the end off.
            let others = tabs.filter { $0.id != focused?.id }.compactMap { Self.named($0.title) }
            let shown = ([tabTitle].compactMap { $0 } + others).filter { !Self.same($0, title) }
            return shown.isEmpty ? title : title + SidebarRowTitleMode.crumb + shown.joined(separator: WorkspaceRowContent.separator)
        }
    }

    /// What VoiceOver reads for the row's name: a name without the workspace (the focused tab
    /// alone, an inherited chat name) still says its workspace first.
    public func spokenRowTitle(_ mode: SidebarRowTitleMode, inheritsSingleChat: Bool = false) -> String {
        let shown = rowTitle(mode, inheritsSingleChat: inheritsSingleChat)
        return namesWorkspace(shown) ? shown : title + SidebarRowTitleMode.crumb + shown
    }

    /// `shown` (a `rowTitle`) says the workspace's name: it is the name, or the name's breadcrumb.
    /// A tab that only starts with the name ("Project setup" in "Project") does not.
    public func namesWorkspace(_ shown: String) -> Bool {
        shown == title || shown.hasPrefix(title + SidebarRowTitleMode.crumb)
    }

    private static func named(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

nonisolated extension SidebarTabKind {
    /// An agent chat or a Home conversation: a tab a workspace may take its name from.
    var isChat: Bool {
        switch self {
        case .agentChat, .conversation: true
        case .terminal, .browser, .remoteTerminal, .newTab, .other: false
        }
    }
}
