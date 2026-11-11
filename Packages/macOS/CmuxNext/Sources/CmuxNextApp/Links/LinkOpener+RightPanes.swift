import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextBridge
import CmuxNextBrowserTabs
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextFocus
import CmuxNextLayout
import CmuxNextSettings
import CmuxNextWakeups

/// What ``LinkOpener`` reads of the panes on a source's right: which hold a kind, the nearest that does, and the
/// measured right column (``RightColumnPlacement``, ``LinkOpenPlacement``).
extension LinkOpener {
    /// Whether `pane` holds a tab of `kind` (``RightColumnPlacement/Kind/isHeld(by:document:)``).
    static func holds(_ pane: PaneController, _ kind: RightColumnPlacement.Kind) -> Bool { holds(tabs: pane.pane.tabs, kind) }

    /// Whether `tabs` hold one of `kind`. The GitHub page is a browser page here (design/pane-placement.md: "A browser
    /// page or link is browser-kind"): a chat's pull request link opens there, so its pane is the browser beside the chat.
    static func holds(tabs: [TabModel], _ kind: RightColumnPlacement.Kind) -> Bool {
        tabs.contains { kind.isHeld(by: $0, document: $0.page == InternalPageID.diff.rawValue)
            || (kind == .browser && $0.page == InternalPageID.github.rawValue) }
    }

    /// The nearest pane right of `source` in `content` that takes new tabs and already holds `kind`
    /// (``LinkOpenPlacement/nearestHolder(of:source:columns:frames:holds:)``): the screen's columns in layout
    /// order, so a strip column scrolled away or not laid out yet still counts, and its pane frames.
    static func nearestHolder(of kind: RightColumnPlacement.Kind, beside source: LayoutPaneID, in content: WorkspaceContentController) -> LayoutPaneID? {
        guard let screen = content.layoutModel.screen(containing: source) else { return nil }
        return LinkOpenPlacement<LayoutPaneID>.nearestHolder(
            of: kind, source: source, columns: screen.layout.visualColumns.map(\.root.panes),
            frames: content.layoutView.navigationFrames(ofScreenContaining: source),
            holds: { id, kind in content.panes[id].map { $0.stripModel.showsNewTabButton && holds($0, kind) } ?? false })
    }

    /// The panes right of `source` in `content`, top to bottom, from the pane frames of the screen
    /// that holds `source`, active or not (``RightColumnPlacement/column(beside:frames:gap:)``),
    /// keeping those that take new tabs. Review of #28044 at bd2b918d: the active screen's frames
    /// read an empty column for a chat on a screen the person switched away from mid-open.
    static func rightPanes(beside source: LayoutPaneID, in content: WorkspaceContentController) -> [LayoutPaneID] {
        RightColumnPlacement.column(beside: source, frames: content.layoutView.navigationFrames(ofScreenContaining: source))
            .filter { content.panes[$0]?.stripModel.showsNewTabButton == true }
    }
}
