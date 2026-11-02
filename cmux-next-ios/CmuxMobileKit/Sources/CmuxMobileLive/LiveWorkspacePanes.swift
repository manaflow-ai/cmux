import CmuxMobileModel
import CmuxMobileTransport
import Foundation

/// The Mac's pane and layout actions from a phone (verify/parity-mac.md, Panes). Every line is
/// one the `daemon` lane already takes (DaemonLanePolicy, cmux-mobile-host `policy.rs`):
/// `split {pane, dir}`, `new-pane {pane}`, `new-pane-right {pane}`, `zoom-pane {pane, mode}`,
/// `swap-pane {pane, dir|target}`, `rename-pane {pane, name}`, `close-pane {pane}`,
/// `set-split-ratio {split, ratio, transaction}`, `undo-layout {pane, revision, confirm_close}`,
/// `move-tab-to-split {surface, pane, edge}`, `move-tab-to-column {surface, pane}` and
/// `move-tab {surface, pane, index}`. A new pane's terminal is the Mac's own new terminal (the
/// login shell; the phone names no program, folder or environment).
extension LiveWorkspaceCreationBackend: WorkspacePaneBackend {
    public func canEditPanes(on macID: String) -> Bool { canEditTabs(on: macID) }

    /// The daemon client, once the pane is one of `workspace`'s on the Mac now.
    private func client(for pane: Int, in workspace: Workspace) throws -> DaemonClient {
        guard canManage(on: workspace.macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        guard layout(of: workspace)?.pane(pane) != nil else {
            throw WorkspaceCreationError("That pane is no longer on the Mac.", isForPerson: true)
        }
        return client
    }

    /// The workspace's panes as the Mac listed them last.
    private func layout(of workspace: Workspace) -> WorkspaceLayout? {
        sync.tree?.workspaces.first { $0.id == workspace.id }?.layout ?? sync.tree?.homeWorkspaces.first { $0.id == workspace.id }?.layout
    }

    /// Sends `command`, then lists the Mac's tree again (the Panes page shows the change).
    private func perform(_ client: DaemonClient, _ command: String, _ params: sending [String: Any]) async throws {
        do {
            try WorkspaceSync.check(await client.request(command, params: params))
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// Sends `command`, then reads the tab the reply names (`surface`) from a fresh list.
    private func openTab(_ client: DaemonClient, _ command: String, _ params: sending [String: Any]) async throws -> WorkspaceTab {
        do {
            let reply = try await client.request(command, params: params)
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let tab = (tree.workspaces + tree.homeWorkspaces).flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return tab
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    public func split(_ pane: Int, _ direction: PaneSplit, in workspace: Workspace) async throws -> WorkspaceTab {
        let client = try self.client(for: pane, in: workspace)
        let tab = try await openTab(client, "split", ["pane": pane, "dir": direction.daemonDirection])
        guard direction.swapsAfter else { return tab }
        // The daemon puts the new pane right of or below the old one; Split Left / Up then
        // swaps the two (the Mac's fork to the left does the same).
        guard let created = sync.tree?.tabPlaces[tab.id]?.pane else { throw WorkspaceCreationError("The Mac doesn't list the new pane") }
        try await perform(client, "swap-pane", ["pane": pane, "target": created])
        return tab
    }

    /// New Column is `new-pane-right`. New Pane (Auto Layout) is the Mac's: a split of the
    /// screen's largest pane along its longer side (never the daemon's `new-pane`, which lays the
    /// whole column out again).
    public func newPane(from pane: Int, column: Bool, in workspace: Workspace) async throws -> WorkspaceTab {
        let client = try self.client(for: pane, in: workspace)
        if column { return try await openTab(client, "new-pane-right", ["pane": pane]) }
        guard let (target, direction) = layout(of: workspace)?.screen(of: pane)?.autoLayoutSplit else {
            throw WorkspaceCreationError("The Mac hasn't listed this workspace's panes")
        }
        return try await split(target, direction, in: workspace)
    }

    public func toggleZoom(_ pane: Int, in workspace: Workspace) async throws {
        try await perform(client(for: pane, in: workspace), "zoom-pane", ["pane": pane, "mode": "toggle"])
    }

    public func swap(_ pane: Int, _ direction: PaneSwap, in workspace: Workspace) async throws {
        try await perform(client(for: pane, in: workspace), "swap-pane", ["pane": pane, "dir": direction.rawValue])
    }

    public func renamePane(_ pane: Int, to name: String, in workspace: Workspace) async throws {
        try await perform(client(for: pane, in: workspace), "rename-pane", ["pane": pane, "name": name])
    }

    /// `close-pane`, then `close-terminal` for each of its terminals no other tab shows, as the
    /// phone's Close Tab ends a closed tab's terminal (the phone has no undo for it).
    public func closePane(_ pane: Int, in workspace: Workspace) async throws {
        let client = try self.client(for: pane, in: workspace)
        let tabs = (sync.tree?.tabPlaces ?? [:]).filter { $0.value.pane == pane }.map(\.key)
        let terminals = sync.tree?.terminalsEndedByClosing(tabs) ?? []
        do {
            try WorkspaceSync.check(await client.request("close-pane", params: ["pane": pane]))
            await end(terminals, on: client)
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The Mac's Equalize Splits on the shown screen: each split of its trees gets the ratio
    /// that gives every cell of its chain an equal share. One `transaction` for the whole
    /// change, so one Undo Layout Change takes it back.
    public func equalizeSplits(in workspace: Workspace) async throws -> Int {
        guard canManage(on: workspace.macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        guard let screen = layout(of: workspace)?.activeScreen, screen.hasSplits else {
            throw WorkspaceCreationError("This workspace has no splits to equalize.", isForPerson: true)
        }
        let splits = screen.unequalSplits
        let transaction = Int.random(in: 1...Int(Int32.max))
        do {
            for split in splits {
                try WorkspaceSync.check(await client.request("set-split-ratio", params: Self.ratioParams(split, transaction: transaction)))
            }
            if !splits.isEmpty { _ = try? await sync.listNow() }
        } catch let error as DaemonReplyError {
            // Splits set before the refusal stay: the page shows them.
            _ = try? await sync.listNow()
            throw WorkspaceCreationError(error.message)
        }
        return splits.count
    }

    nonisolated static func ratioParams(_ split: WorkspaceLayout.EqualizedSplit, transaction: Int) -> sending [String: Any] {
        ["split": split.split, "ratio": split.equalized, "transaction": transaction]
    }

    /// `undo-layout` on the shown screen (named by its focused pane). An undo that closes
    /// panes comes back as a question first; the yes sends that screen's `revision` with
    /// `confirm_close`, named by the same pane, so it never lands on a screen the Mac switched
    /// to meanwhile.
    public func undoLayout(in workspace: Workspace, confirming confirmation: LayoutUndoConfirmation?) async throws -> LayoutUndoOutcome {
        guard canManage(on: workspace.macID), let client = sync.daemon else { throw WorkspaceCreationError("Not connected") }
        let screen: Int
        let pane: Int
        if let confirmation {
            // The pane must still be on the screen the question was about.
            guard layout(of: workspace)?.screen(of: confirmation.pane)?.id == confirmation.screen else {
                throw WorkspaceCreationError("The layout changed on the Mac. Try Undo Layout Change again.", isForPerson: true)
            }
            (screen, pane) = (confirmation.screen, confirmation.pane)
        } else {
            guard let shown = layout(of: workspace)?.activeScreen,
                  let focused = (shown.panes.first(where: \.isFocused) ?? shown.panes.first)?.id else {
                throw WorkspaceCreationError("The Mac hasn't listed this workspace's panes")
            }
            (screen, pane) = (shown.id, focused)
        }
        var params: [String: Any] = ["pane": pane]
        if let confirmation {
            params["revision"] = confirmation.revision
            params["confirm_close"] = true
        }
        do {
            let reply = try WorkspaceSync.check(await client.request("undo-layout", params: params))
            let outcome = try Self.undoOutcome(reply, screen: screen, pane: pane)
            if outcome == .undone { _ = try? await sync.listNow() }
            return outcome
        } catch let error as DaemonReplyError {
            switch error.code {
            case "layout-undo-unavailable": throw WorkspaceCreationError("There's no layout change to undo.", isForPerson: true)
            case "layout-undo-stale": throw WorkspaceCreationError("The layout changed on the Mac. Try Undo Layout Change again.", isForPerson: true)
            default: throw WorkspaceCreationError(error.message)
            }
        }
    }

    /// The reply's one complete variant (`undone:true` with its screen and revision, or
    /// `confirmation_required` with the screen, its revision and the pane ids it closes);
    /// anything else is a protocol error. A question must be about `screen`, the screen of the
    /// `pane` it was asked for, and keeps both for the yes.
    nonisolated static func undoOutcome(_ reply: [String: Any], screen: Int, pane: Int) throws -> LayoutUndoOutcome {
        let data = reply["data"] as? [String: Any] ?? [:]
        let replyScreen = Self.integer(data["screen"])
        let revision = Self.integer(data["revision"]).flatMap { $0 >= 0 ? UInt64($0) : nil }
        if data["undone"] as? Bool == true, data["confirmation_required"] as? Bool != true,
           replyScreen != nil, revision != nil { return .undone }
        if data["undone"] as? Bool == false, data["confirmation_required"] as? Bool == true,
           replyScreen == screen, let revision,
           let closes = data["closes_panes"] as? [Any], !closes.isEmpty, closes.allSatisfy({ (Self.integer($0) ?? -1) >= 0 }) {
            return .needsConfirmation(LayoutUndoConfirmation(screen: screen, pane: pane, revision: revision, closing: closes.count))
        }
        throw WorkspaceCreationError("The Mac's undo reply wasn't readable")
    }

    /// A JSON integer, never a boolean, a fraction or a string (an `Id` is one that isn't negative).
    nonisolated static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded() else { return nil }
        return number.intValue
    }

    public func moveTab(_ tab: WorkspaceTab, toNewSplit edge: TabSplitEdge, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[tab.id] else { throw WorkspaceCreationError("The Mac doesn't list this tab") }
        // The daemon splits a tab out only of a pane that keeps another tab.
        guard (sync.tree?.tabPlaces ?? [:]).values.contains(where: { $0.pane == place.pane && $0.index != place.index }) else {
            throw WorkspaceCreationError("This is the pane's only tab. Split the pane instead.", isForPerson: true)
        }
        try await perform(client, "move-tab-to-split", ["surface": surface, "pane": place.pane, "edge": edge.daemonEdge])
    }

    public func moveTabToNewColumn(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[tab.id] else { throw WorkspaceCreationError("The Mac doesn't list this tab") }
        try await perform(client, "move-tab-to-column", ["surface": surface, "pane": place.pane])
    }

    /// `move-tab` to the end of `pane`'s tabs (its insertion point past the last).
    public func moveTab(_ tab: WorkspaceTab, toPane pane: Int, in workspace: Workspace) async throws {
        let (client, surface) = try target(tab, in: workspace)
        guard let destination = layout(of: workspace)?.pane(pane) else {
            throw WorkspaceCreationError("That pane is no longer on the Mac.", isForPerson: true)
        }
        guard sync.tree?.tabPlaces[tab.id]?.pane != pane else { return }
        // Past every tab the pane holds on the Mac, the ones the phone doesn't list too.
        try await perform(client, "move-tab", ["surface": surface, "pane": pane, "index": destination.tabCount])
    }

    /// Fork Conversation to a destination, as the Mac's `openFork`: the copy opens as a tab
    /// beside the chat, then moves to a new split on that side (`move-tab-to-split`) or to a
    /// new workspace (`move-tab-to-new-workspace`, named as the Mac names one).
    public func forkAgentChat(_ tab: WorkspaceTab, to destination: ChatForkDestination, in workspace: Workspace) async throws -> WorkspaceTab {
        let copy = try await forkAgentChat(tab, in: workspace)
        guard let home = sync.tree?.workspaces.first(where: { ws in ws.tabs.contains { $0.id == copy.id } })
            ?? sync.tree?.homeWorkspaces.first(where: { ws in ws.tabs.contains { $0.id == copy.id } }) else { return copy }
        if let edge = destination.splitEdge {
            try await moveTab(copy, toNewSplit: edge, in: home)
        } else if destination == .workspace {
            _ = try await moveTab(copy, from: home, toWorkspace: nil)
        }
        return sync.tree.flatMap { tree in (tree.workspaces + tree.homeWorkspaces).flatMap(\.tabs).first { $0.id == copy.id } } ?? copy
    }
}
