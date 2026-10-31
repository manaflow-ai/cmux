#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import CmuxTabsKit
import SwiftUI

/// The Mac's pane actions on the phone (verify/parity-mac.md, Panes): the Panes page shows the
/// workspace's panes with their tabs, and each action goes to the Mac (`WorkspacePaneBackend`).
/// The page shows what the Mac lists; nothing changes here before the Mac says so.
extension WorkspaceTabsSource {
    var paneBackend: (any WorkspacePaneBackend)? { creator?.backend as? any WorkspacePaneBackend }

    /// Panes can be changed on this workspace's Mac now.
    public var canEditPanes: Bool {
        guard let workspace, let paneBackend else { return false }
        return paneBackend.canEditPanes(on: workspace.macID)
    }

    /// The workspace's panes as its Mac listed them last (nil: not listed yet).
    public var layout: WorkspaceLayout? { workspace?.layout }

    /// The page menu's way to the Panes page, once the Mac listed the workspace's panes.
    func panesItems() -> [TabsKitMenuItem] {
        guard let layout, !layout.panes.isEmpty else { return [] }
        let count = layout.panes.count
        return [TabsKitMenuItem(id: "panes", title: count == 1 ? "Panes" : "Panes (\(count))", systemImage: "rectangle.split.2x1") { [weak self] in
            self?.route = .panes
        }]
    }

    /// The pane's name, else "Pane 2".
    public func title(of pane: WorkspaceLayout.Pane) -> String { layout?.title(of: pane) ?? "Pane" }

    /// The tabs of `pane`, in its order, read from the workspace (observed: the Panes page
    /// redraws when a tab changes; `workspaceTab` is the unobserved listed copy).
    public func tabs(of pane: WorkspaceLayout.Pane) -> [WorkspaceTab] {
        let tabs = workspace?.tabs ?? []
        return pane.tabIDs.compactMap { id in tabs.first { $0.id == id } }
    }

    /// Runs one pane action on the Mac; a refusal shows in the toast ("Couldn't zoom Pane 2.").
    private func onMac(_ verb: String, _ title: String, _ body: @MainActor (any WorkspacePaneBackend, Workspace) async throws -> Void) async {
        guard let workspace, let paneBackend else { return show("Connect to \(macName) first.") }
        do {
            try await body(paneBackend, workspace)
        } catch {
            show(error, doing: verb, title)
        }
    }

    /// Split Right / Down / Left / Up: the new pane's terminal becomes this workspace's tab.
    public func split(_ pane: WorkspaceLayout.Pane, _ direction: PaneSplit) async {
        await openInNewPane(pane, verb: "split") { try await $0.split(pane.id, direction, in: $1) }
    }

    /// New Pane (Auto Layout) or New Column, from `pane`'s column.
    public func newPane(from pane: WorkspaceLayout.Pane, column: Bool) async {
        await openInNewPane(pane, verb: "open a pane beside") { try await $0.newPane(from: pane.id, column: column, in: $1) }
    }

    private func openInNewPane(_ pane: WorkspaceLayout.Pane, verb: String,
                               _ open: @MainActor (any WorkspacePaneBackend, Workspace) async throws -> WorkspaceTab) async {
        guard pendingTabTitle == nil else { return }
        pendingTabTitle = "New Terminal"
        defer { pendingTabTitle = nil }
        let title = self.title(of: pane)
        await onMac(verb, title) { backend, workspace in
            let tab = try await open(backend, workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tab.id }) == true { activate(tab.id) }
        }
    }

    public func toggleZoom(_ pane: WorkspaceLayout.Pane) async {
        await onMac(pane.isZoomed ? "unzoom" : "zoom", title(of: pane)) { try await $0.toggleZoom(pane.id, in: $1) }
    }

    public func swap(_ pane: WorkspaceLayout.Pane, _ direction: PaneSwap) async {
        await onMac("swap", title(of: pane)) { try await $0.swap(pane.id, direction, in: $1) }
    }

    /// Rename Pane…: an empty name clears the pane's name (the Mac then shows its place).
    public func renamePane(_ pane: WorkspaceLayout.Pane, to name: String) async {
        renamingPane = nil
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != pane.name else { return }
        await onMac("rename", title(of: pane)) { try await $0.renamePane(pane.id, to: name, in: $1) }
    }

    /// Close Pane: asks first when a tab in it runs a program or a working agent, as closing
    /// those tabs one by one would.
    public func closePane(_ pane: WorkspaceLayout.Pane) async {
        guard let workspace else { return }
        guard await confirmClose(tabs(of: pane), in: workspace) else { return }
        await onMac("close", title(of: pane)) { try await $0.closePane(pane.id, in: $1) }
    }

    public func equalizeSplits() async {
        await onMac("equalize", "the splits") { backend, workspace in
            if try await backend.equalizeSplits(in: workspace) == 0 { show("The splits are already equal.") }
        }
    }

    /// Undo Layout Change. One that closes panes asks first (`pendingLayoutUndo`).
    /// `confirmation`: the person's yes to that question; it undoes on the screen it was about.
    public func undoLayout(confirming confirmation: LayoutUndoConfirmation? = nil) async {
        pendingLayoutUndo = nil
        await onMac("undo", "the layout change") { backend, workspace in
            switch try await backend.undoLayout(in: workspace, confirming: confirmation) {
            case .undone:
                show("Undid the last layout change.")
            case .needsConfirmation(let question):
                pendingLayoutUndo = question
            }
        }
    }

    /// Move Tab to New Split on `edge` of its pane.
    public func moveTab(_ tab: WorkspaceTab, toNewSplit edge: TabSplitEdge) async {
        await onMac("move", tab.title) { try await $0.moveTab(tab, toNewSplit: edge, in: $1) }
    }

    public func moveTabToNewColumn(_ tab: WorkspaceTab) async {
        await onMac("move", tab.title) { try await $0.moveTabToNewColumn(tab, in: $1) }
    }

    /// Move Tab to Pane…: the end of `pane`'s tabs.
    public func moveTab(_ tab: WorkspaceTab, to pane: WorkspaceLayout.Pane) async {
        await onMac("move", tab.title) { try await $0.moveTab(tab, toPane: pane.id, in: $1) }
    }

    /// Fork Conversation…: a copy of the chat at `destination`. In this workspace it comes to the
    /// front, as on the Mac; in a new workspace the toast says where it went.
    public func fork(_ id: TabsKitTab.ID, to destination: ChatForkDestination) async {
        forkingTab = nil
        if destination == .tab { return await fork(id) }
        guard let tab = workspaceTab(id), tab.kind == .agent, pendingTabTitle == nil else { return }
        pendingTabTitle = "Fork"
        defer { pendingTabTitle = nil }
        await onMac("fork", tab.title) { backend, workspace in
            let copy = try await backend.forkAgentChat(tab, to: destination, in: workspace)
            if store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == copy.id }) == true {
                activate(copy.id)
                openedTab = copy.id
            } else {
                let landed = store.workspaces.first { ws in ws.macID == workspace.macID && ws.tabs.contains { $0.id == copy.id } }
                show("Forked \(tab.title) to \(landed?.title ?? "a new workspace").")
                CmuxMobileTheme.standard.haptics.success()
            }
        }
    }
}
#endif
