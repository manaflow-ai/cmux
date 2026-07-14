import Foundation

struct UsageTipsCatalog {
    let tips: [UsageTip]

    init(tips: [UsageTip]? = nil) {
        self.tips = tips ?? Self.curatedTips
    }

    func unseenTips(seenTipIDs: Set<String>) -> [UsageTip] {
        tips.filter { !seenTipIDs.contains($0.id.rawValue) }
    }

    func nextUnseenTip(seenTipIDs: Set<String>) -> UsageTip? {
        unseenTips(seenTipIDs: seenTipIDs).first
    }

    private static let curatedTips: [UsageTip] = [
        UsageTip(
            id: .globalSearch,
            title: String(localized: "usageTips.globalSearch.title", defaultValue: "Search every workspace"),
            body: String(localized: "usageTips.globalSearch.body", defaultValue: "Search panel titles plus browser and Markdown content across every open workspace."),
            shortcutAction: .globalSearch
        ),
        UsageTip(
            id: .canvasLayout,
            title: String(localized: "usageTips.canvasLayout.title", defaultValue: "Arrange panes on a canvas"),
            body: String(localized: "usageTips.canvasLayout.body", defaultValue: "Switch the current workspace to a spatial canvas where panes can move and resize freely."),
            shortcutAction: .toggleCanvasLayout
        ),
        UsageTip(
            id: .reopenBrowser,
            title: String(localized: "usageTips.reopenBrowser.title", defaultValue: "Reopen a closed browser"),
            body: String(localized: "usageTips.reopenBrowser.body", defaultValue: "Bring back the browser panel you just closed without rebuilding it."),
            shortcutAction: .reopenClosedBrowserPanel
        ),
        UsageTip(
            id: .workspaceGroups,
            title: String(localized: "usageTips.workspaceGroups.title", defaultValue: "Group related workspaces"),
            body: String(localized: "usageTips.workspaceGroups.body", defaultValue: "Select workspaces in the sidebar, then group them to keep a project together."),
            shortcutAction: .groupSelectedWorkspaces
        ),
        UsageTip(
            id: .diffViewer,
            title: String(localized: "usageTips.diffViewer.title", defaultValue: "Review changes in cmux"),
            body: String(localized: "usageTips.diffViewer.body", defaultValue: "Open the built-in diff viewer for the current repository. Navigate with j/k, gg/G, and ]f/[f."),
            shortcutAction: .openDiffViewer
        ),
        UsageTip(
            id: .splitZoom,
            title: String(localized: "usageTips.splitZoom.title", defaultValue: "Zoom the focused split"),
            body: String(localized: "usageTips.splitZoom.body", defaultValue: "Expand the focused split to fill its workspace, then use the same shortcut to return."),
            shortcutAction: .toggleSplitZoom
        ),
        UsageTip(
            id: .keyboardSplitFocus,
            title: String(localized: "usageTips.keyboardSplitFocus.title", defaultValue: "Move focus without the mouse"),
            body: String(localized: "usageTips.keyboardSplitFocus.body", defaultValue: "Move focus to the split on the left. The matching Up, Down, and Right commands are customizable too."),
            shortcutAction: .focusLeft
        ),
        UsageTip(
            id: .layoutTemplate,
            title: String(localized: "usageTips.layoutTemplate.title", defaultValue: "Save this pane layout"),
            body: String(localized: "usageTips.layoutTemplate.body", defaultValue: "Save the current workspace's pane arrangement so you can create the same layout again."),
            shortcutAction: .saveLayoutTemplate
        ),
        UsageTip(
            id: .previousSession,
            title: String(localized: "usageTips.previousSession.title", defaultValue: "Restore your previous session"),
            body: String(localized: "usageTips.previousSession.body", defaultValue: "Reopen the windows, workspaces, and panels saved from your previous cmux launch."),
            shortcutAction: .reopenPreviousSession
        ),
        UsageTip(
            id: .vault,
            title: String(localized: "usageTips.vault.title", defaultValue: "Jump straight to the Vault"),
            body: String(localized: "usageTips.vault.body", defaultValue: "The Vault finds resumable coding-agent sessions, including Claude Code and Codex, so you can jump back in."),
            shortcutAction: .switchRightSidebarToSessions
        ),
        UsageTip(
            id: .browserFocus,
            title: String(localized: "usageTips.browserFocus.title", defaultValue: "Browse without distractions"),
            body: String(localized: "usageTips.browserFocus.body", defaultValue: "Hide cmux chrome around the focused browser. Use the same shortcut to leave focus mode."),
            shortcutAction: .toggleBrowserFocusMode
        ),
        UsageTip(
            id: .terminalCopyMode,
            title: String(localized: "usageTips.terminalCopyMode.title", defaultValue: "Select terminal text by keyboard"),
            body: String(localized: "usageTips.terminalCopyMode.body", defaultValue: "Enter keyboard-driven selection mode, then copy terminal text without touching the mouse."),
            shortcutAction: .toggleTerminalCopyMode
        ),
    ]
}
