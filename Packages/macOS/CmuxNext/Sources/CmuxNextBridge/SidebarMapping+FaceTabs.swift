public import CmuxNextDaemon
import Foundation
import os

/// When the face rules could not read one workspace's request: it has no picked tab, and this says so.
private let faceTabsLog = Logger(subsystem: "com.cmuxterm.app.next", category: "sidebar.face")

/// Which tab names a workspace, for the callers that name one workspace (the titlebar, the auto namer, Copy Agent
/// Identifier): the same Rust rules the sidebar rows read (`SidebarFaceBatch`, `cmux_sidebar_face_rows`), one row
/// per call, O(the workspace's tabs). An agent chat names its row over an idle shell beside it (Leo, 2026-10-28:
/// "we don't want to just be seeing these bare terminals. It's weird to have that be the thing that's showing. I'd
/// rather just see the other thing instead of that, you know, tilde.").
extension SidebarMapping {
    /// The tabs one workspace's face picks.
    public struct FaceTabs {
        /// The selected tab of the most recently focused pane (the first stored one on a tie); nil for a workspace
        /// with no tabs.
        public var front: TabModel?
        /// The tab the row and its window's titlebar are named for: `front`, unless it is an idle shell or a New
        /// Tab page while the workspace has an agent chat; then that chat (a working or waiting one first).
        public var label: TabModel?
        /// The one tab the row and the titlebar read their name and icon from: `label`, or for a browser one the
        /// work it yields to (`work`), so focus moving to a page beside a chat leaves both the chat's.
        public var face: TabModel?
        /// The tab a browser front tab yields its name to (a PR opened in a split,
        /// https://github.com/manaflow-ai/cmux/issues/22249): the selected tab of the most recently focused pane
        /// that shows a chat or terminal; a Home, page or app tab is passed over. Nil while every pane shows a page.
        public var work: TabModel?
        /// The agent chat whose last message the row shows: `label`'s when it is one, else the first chat.
        public var chat: TabModel?

        public init(front: TabModel? = nil, label: TabModel? = nil, face: TabModel? = nil, work: TabModel? = nil,
                    chat: TabModel? = nil) {
            self.front = front
            self.label = label
            self.face = face
            self.work = work
            self.chat = chat
        }
    }

    /// The tabs `workspace`'s face picks, its panes showing the tabs `selectedTab` picks (the window's selection;
    /// nil: the daemon's default tab). `newTabPages` are the ids of its tabs still on the New Tab page. A call takes
    /// its own buffers (one workspace's: O(its tabs)); the sidebar's many rows reuse the window's (`FaceRowBatch`).
    ///
    /// A caller in an observation (the titlebar's name) is woken by the title, folder, running command and title
    /// activity of the front tab only, never by another tab's: the rules read those of the front tab alone (is it
    /// an idle shell?), so only its are given. The rules answer twice: first with no tab's text, which gives the
    /// front tab (panes and selection decide it), then with the front tab's text for the other picks.
    public func faceTabs(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                         newTabPages: Set<String> = []) -> FaceTabs {
        let batch = SidebarFaceBatch(home: home)
        guard let front = stageFront(batch, workspace, selectedTab: selectedTab, newTabPages: newTabPages) else { return FaceTabs() }
        batch.addFrontFacts(front)
        guard let reply = batch.run() else {
            faceTabsLog.error("sidebar face rules could not read workspace \(workspace.id, privacy: .public)")
            return FaceTabs()
        }
        let tabs = batch.tabs, picks = reply.picks(0)
        func at(_ index: Int?) -> TabModel? { index.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
        return FaceTabs(front: at(picks.front), label: at(picks.label), face: at(picks.face), work: at(picks.work),
                        chat: at(picks.chat))
    }

    /// `faceTabs(_:selectedTab:).front` alone: the selected tab of `workspace`'s most recently focused pane. It
    /// reads no tab's text, so a caller in an observation follows the panes, their tab lists and the selection only.
    public func frontTab(_ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?) -> TabModel? {
        let batch = SidebarFaceBatch(home: home)
        return stageFront(batch, workspace, selectedTab: selectedTab, newTabPages: []).map { batch.tabs[$0] }
    }

    /// Stages `workspace` in `batch` with no tab's text and returns the index of its front tab in `batch.tabs`;
    /// nil for a workspace with no tabs, or (logged) when the rules could not read it.
    private func stageFront(_ batch: SidebarFaceBatch, _ workspace: WorkspaceModel, selectedTab: (PaneModel) -> String?,
                            newTabPages: Set<String>) -> Int? {
        // Only the picks are read: the row facts (status, machine, list titles, brands) do not change them.
        batch.reset(showsUnread: false, newTabTitled: false)
        batch.appendPicks(workspace, selectedTab: selectedTab, newTabPages: newTabPages)
        guard let reply = batch.run() else {
            faceTabsLog.error("sidebar face rules could not read workspace \(workspace.id, privacy: .public)")
            return nil
        }
        return reply.picks(0).front.flatMap { batch.tabs.indices.contains($0) ? $0 : nil }
    }
}
