import Foundation

/// The confirmed mirror plus one ordered intent log (plans/cmux-next/
/// OWNERSHIP-PRINCIPLES.md, "Clients are projections"; ownership.md step 4).
///
/// The records show the visible state: the confirmed mirror with every
/// pending intent applied in order. Daemon events and snapshots never
/// apply to the visible state: `withOverlayLifted` first undoes the
/// overlay exactly (each apply recorded its inverse, and nothing else
/// writes the records in between; debug builds check that), applies them
/// to the confirmed records, drops the intents that are now settled and
/// applies the rest again in order.
///
/// An intent leaves the log exactly once: on the daemon's echo of its
/// transaction, once the store applied every event up to its settle
/// sequence (the event sequence read after the command's reply, a
/// read-your-writes barrier; `mutation-echo-v1`'s `request-settled` will
/// supply the same sequence through `noteSettled`), or on rejection.
extension DaemonStore {
    /// Adds `intent` to the log and shows it. The caller sends the command
    /// carrying `transaction`, then calls `noteSettled` after the reply or
    /// `rejectIntent` when it failed.
    public func intend(_ intent: Intent, transaction: ClientTransactionID) {
        if overlayLifted {
            // Applied with the rest when the lift ends.
            _ = intentLog.append(intent, transaction: transaction)
            return
        }
        verifyMirrorUnchanged(before: "intent")
        guard intentLog.append(intent, transaction: transaction) else { return }
        intentLog.setUndo(applyOverlay(intent), at: intentLog.entries.count - 1)
        recomputeSidebarIfNeeded()
        recordMirror()
        workspaceListMayHaveChanged()
    }

    /// The overlay moved a workspace or changed its group: one sidebar
    /// flattening once the visible state is complete.
    private func recomputeSidebarIfNeeded() {
        guard sidebarNeedsRecompute else { return }
        sidebarNeedsRecompute = false
        recomputeSidebar()
    }

    /// The command for `transaction` replied: its effects are bounded by
    /// daemon event `sequence` (`DaemonConnection.eventSequence()` read
    /// after the reply). The intent settles once the store applied every
    /// event up to it, at once if it already has.
    public func noteSettled(_ transaction: ClientTransactionID, at sequence: UInt64) {
        intentLog.settle(transaction, at: sequence)
        settleDueIntents()
    }

    /// The command for `transaction` failed: the intent leaves the log and
    /// the visible state returns to the confirmed mirror (plus the others).
    public func rejectIntent(_ transaction: ClientTransactionID) {
        guard intentLog.contains(transaction) else { return }
        withOverlayLifted(writer: "intent rejection") { settleIntent(transaction, .rejected) }
    }

    /// The pending intents in order.
    public var pendingIntents: [Intent] { intentLog.entries.map(\.kind) }
    public var hasPendingIntents: Bool { !intentLog.isEmpty }

    /// The daemon echoed `transaction`. An echo carried by an event the
    /// store could not apply exactly (it resyncs) settles only once the
    /// snapshot covering `resyncSequence` is applied, so the tab never
    /// shows back at its old place in between.
    func settleIntentOnEcho(_ transaction: ClientTransactionID, needsResync: Bool, sequence: UInt64?) {
        guard intentLog.contains(transaction) else { return }
        if needsResync {
            if let sequence { intentLog.settle(transaction, at: sequence) }
            return
        }
        withOverlayLifted(writer: "intent echo") { settleIntent(transaction, .echoed) }
    }

    /// Drops the intents whose settle sequence the store reached (outside
    /// an apply; inside one, the lift's end does it).
    func settleDueIntents() {
        guard !overlayLifted, applyDepth == 0, intentLog.hasDue(appliedSequence: appliedSequence) else { return }
        withOverlayLifted(writer: "intent settlement") {}
    }

    /// Reported after the overlay is back (`withOverlayLifted`).
    private func settleIntent(_ transaction: ClientTransactionID, _ settlement: IntentSettlement) {
        guard intentLog.remove(transaction) != nil else { return }
        intentSettlements.append((transaction, settlement))
    }

    /// Runs `body` (event or snapshot apply, a settlement) on the confirmed
    /// records, then shows the pending intents again. `snapshot` settles the
    /// intents waiting for one. Nested calls run `body` directly.
    func withOverlayLifted<T>(writer: String = "daemon apply", snapshot: Bool = false, _ body: () -> T) -> T {
        guard !overlayLifted else { return body() }
        verifyMirrorUnchanged(before: writer)
        overlayLifted = true
        liftOverlay()
        let result = body()
        for intent in intentLog.removeDue(appliedSequence: appliedSequence, snapshot: snapshot) {
            intentSettlements.append((intent.transaction, .applied))
        }
        let confirmedTabs = debugTabCensus()
        restoreOverlay()
        overlayLifted = false
        recomputeSidebarIfNeeded()
        checkOverlayConservation(confirmed: confirmedTabs)
        recordMirror()
        workspaceListMayHaveChanged()
        // Observers see the visible state with the other intents on it.
        let settled = intentSettlements
        intentSettlements.removeAll()
        for (transaction, settlement) in settled { onIntentSettled?(transaction, settlement) }
        return result
    }

    /// A new connection replaces the last one (`run(connection:)`): its
    /// event sequences restart from its own serial, so the store's
    /// sequences reset, and intents whose reply came settle with its first
    /// snapshot.
    func beginConnection() {
        snapshotBarrier = 0
        if appliedSequence != 0 { appliedSequence = 0 }
        intentLog.connectionReplaced()
    }

    /// Undoes every overlay apply, newest first.
    private func liftOverlay() {
        for index in intentLog.entries.indices.reversed() {
            if let undo = intentLog.entries[index].undo { self.undo(undo) }
            intentLog.setUndo(nil, at: index)
        }
    }

    /// Applies every pending intent in order, recording each inverse.
    private func restoreOverlay() {
        for index in intentLog.entries.indices {
            intentLog.setUndo(applyOverlay(intentLog.entries[index].kind), at: index)
        }
    }

    /// Applies one intent to the records. Idempotent and conservation-safe:
    /// a tab, workspace or group that is not in the mirror, or a value
    /// already in place, changes nothing (returns nil).
    private func applyOverlay(_ intent: Intent) -> IntentUndo? {
        switch intent {
        case .moveTab(let surface, let toPane, let index):
            guard let target = panesByHandle[toPane], let source = pane(containing: surface),
                  let from = source.tabs.firstIndex(where: { $0.surface == surface }) else { return nil }
            let final = source === target ? min(max(index, 0), target.tabs.count - 1) : min(max(index, 0), target.tabs.count)
            if source === target, from == final { return nil }
            guard let tab = source.removeTab(surface: surface) else { return nil }
            target.insertTab(tab, at: final)
            return .moveTab(surface: surface, fromPane: source.handle, fromIndex: from, toPane: target.handle)
        case .renameTab(let surface, let name):
            guard let tab = tabsBySurface[surface], tab.name != name else { return nil }
            let previous = tab.name
            tab.setName(name)
            return .tabName(surface: surface, name: previous)
        case .setTabPinned(let surface, let pinned):
            guard let tab = tabsBySurface[surface], tab.pinned != pinned else { return nil }
            tab.setPinned(pinned)
            return .tabPinned(surface: surface, pinned: !pinned)
        case .renameWorkspace(let key, let name):
            guard let workspace = workspacesByKey[key], workspace.name != name else { return nil }
            let previous = workspace.name
            workspace.setName(name)
            return .workspaceName(key: key, name: previous)
        case .moveWorkspace(let key, let index):
            guard let from = workspaces.firstIndex(where: { $0.key == key }) else { return nil }
            return place(at: from, index: min(max(index, 0), workspaces.count - 1), group: workspaces[from].group)
        case .setWorkspaceGroup(let key, let group):
            guard let from = workspaces.firstIndex(where: { $0.key == key }) else { return nil }
            return place(at: from, index: from, group: group)
        case .placeWorkspace(let key, let group, let index):
            guard let from = workspaces.firstIndex(where: { $0.key == key }) else { return nil }
            return place(at: from, index: sectionPlacement(from: from, group: group, index: index), group: group)
        case .setWorkspaceGroupCollapsed(let id, let collapsed):
            guard let group = group(id), group.collapsed != collapsed else { return nil }
            group.setCollapsed(collapsed)
            return .workspaceGroupCollapsed(id, collapsed: !collapsed)
        case .setTabGroupCollapsed(let id, let collapsed):
            guard let group = tabGroupsByID[id], group.collapsed != collapsed else { return nil }
            group.setCollapsed(collapsed)
            return .tabGroupCollapsed(id, collapsed: !collapsed)
        }
    }

    private func undo(_ undo: IntentUndo) {
        switch undo {
        case .moveTab(let surface, let fromPane, let fromIndex, let toPane):
            guard let source = panesByHandle[fromPane], let target = panesByHandle[toPane],
                  let tab = target.removeTab(surface: surface) else {
                return reportMirrorViolation("intent overlay undo found surface \(surface) missing from pane \(toPane)")
            }
            source.insertTab(tab, at: fromIndex)
        case .tabName(let surface, let name):
            tabsBySurface[surface]?.setName(name)
        case .tabPinned(let surface, let pinned):
            tabsBySurface[surface]?.setPinned(pinned)
        case .workspaceName(let key, let name):
            workspacesByKey[key]?.setName(name)
        case .workspacePlace(let key, let index, let group):
            guard let from = workspaces.firstIndex(where: { $0.key == key }) else {
                return reportMirrorViolation("intent overlay undo found workspace \(key) missing")
            }
            _ = place(at: from, index: index, group: group)
        case .workspaceGroupCollapsed(let id, let collapsed):
            group(id)?.setCollapsed(collapsed)
        case .tabGroupCollapsed(let id, let collapsed):
            tabGroupsByID[id]?.setCollapsed(collapsed)
        }
    }

    /// Moves the workspace at `from` to daemon-order `index` in `group`;
    /// returns the inverse, or nil when it was there already.
    private func place(at from: Int, index: Int, group: WorkspaceGroupID?) -> IntentUndo? {
        let model = workspaces[from]
        guard index != from || model.group != group, let key = model.key else { return nil }
        let undo = IntentUndo.workspacePlace(key: key, index: from, group: model.group)
        model.setGroup(group)
        if index != from {
            workspaces.remove(at: from)
            workspaces.insert(model, at: index)
        }
        sidebarNeedsRecompute = true
        return undo
    }

    /// cmux-tui's `move-workspace-to-group` placement (presentation.rs
    /// `move_workspace_to_group`) on the records: a section is the daemon
    /// order filtered by group, so the workspace goes before the member now
    /// at `index`, after the last member, or stays put in an empty section.
    /// Kept here because the intent names a section index, which only this
    /// rule turns into a daemon-order index on the current mirror.
    private func sectionPlacement(from old: Int, group: WorkspaceGroupID?, index: Int) -> Int {
        let remaining = workspaces.indices.filter { $0 != old }
        let members = remaining.filter { workspaces[$0].group == group }
        let position = { (target: Int) in remaining.firstIndex(of: target) ?? old }
        var new = old
        if let last = members.last {
            new = index < members.count ? position(members[index]) : position(last) + 1
        }
        return min(new, workspaces.count - 1)
    }
}
