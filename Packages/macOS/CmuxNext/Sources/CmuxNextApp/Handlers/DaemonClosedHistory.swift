import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowserHistory
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation

/// Recently closed tabs, screens, and workspaces as the daemon records them
/// (`closed-history-v2`, state-ownership.md 2, reopen-closed.md). The only
/// closed history: the app keeps no copy. One shared path for Cmd-Shift-T,
/// Reopen Closed Screen, Reopen Closed Workspace, the undo toasts, Search
/// Tabs and every history list: read the item from the mirrored history
/// (`DaemonStore.closedItems`), reopen it with `closed.reopen`, and show
/// what came back. Every surface kind the daemon records (terminal, browser,
/// agent, page and viewer tabs) comes back through the same op.
@MainActor
enum DaemonClosedHistory {
    struct Entry: Sendable {
        var item: ClosedItem
        var daemon: DaemonService
    }

    /// A `closed.reopen` reply, with the connection that carried it.
    typealias Reply = Result<(connection: DaemonConnection, item: StateResourceClient.ReopenedItem), any Error>
    /// What one Cmd-Shift-T press sent (``reopenNewest(for:in:)``): its item and the reply.
    typealias Sent = (entry: Entry, reply: Reply)

    /// Every connected daemon's closed items of `kinds`, newest first.
    static func entries(_ kinds: Set<ClosedItem.Kind>, in services: AppServices) -> [Entry] {
        services.machines.daemons.filter(\.store.servesStateResources).flatMap { daemon in
            daemon.store.closedItems.filter { kinds.contains($0.kind) }.map { Entry(item: $0, daemon: daemon) }
        }.sorted { $0.item.closedAtMs > $1.item.closedAtMs }
    }

    /// The id a history list gives a daemon-recorded item (`HistoryService`).
    static func historyID(_ id: String) -> String { "daemon:" + id }

    /// The daemon item id of a history list id, nil for the app's trackers.
    static func daemonID(fromHistoryID id: String) -> String? {
        id.hasPrefix("daemon:") ? String(id.dropFirst("daemon:".count)) : nil
    }

    /// The page a closed item on `machine` is only, by machine and address: a closed tab of one
    /// browser on a real address, as the daemon keys it (`closed_page`, Leo 2026-10-14). nil for a
    /// terminal, chat, page tab, screen, workspace, window, group or close of several tabs:
    /// nothing tells one close of those from another (two shells in one folder).
    nonisolated static func pageKey(_ item: ClosedItem, machine: String) -> [String]? {
        let tabs = item.tabs
        guard item.kind == .tab, item.group == nil, tabs.count == 1, let tab = tabs.first, tab.kind == "browser",
              !tab.empty, tab.page == nil, let url = tab.url, !url.isEmpty, url != "about:blank" else { return nil }
        return [machine, url]
    }

    /// `closed` (newest first, each as its item and machine) with a page closed again
    /// (``pageKey(_:machine:)``) once, at its newest close: Recently Closed and Search Tabs list a
    /// page once.
    nonisolated static func newestOnce<T>(_ closed: [T], _ item: (T) -> (item: ClosedItem, machine: String)) -> [T] {
        var seen = Set<[String]>()
        return closed.filter { value in
            let (closedItem, machine) = item(value)
            return pageKey(closedItem, machine: machine).map { seen.insert($0).inserted } ?? true
        }
    }

    /// Every close the row of `target` stands for, among `closed`: for a page
    /// (``pageKey(_:machine:)``) every close of it, so removing the row leaves none to take its
    /// place; else `target` alone.
    nonisolated static func closes<T>(of target: T, among closed: [T], _ item: (T) -> (item: ClosedItem, machine: String)) -> [T] {
        let own = item(target)
        guard let page = pageKey(own.item, machine: own.machine) else { return [target] }
        return closed.filter { value in
            let other = item(value)
            return pageKey(other.item, machine: other.machine) == page
        }
    }

    /// True when some connected daemon records closed history.
    static func isServed(in services: AppServices) -> Bool {
        services.machines.daemons.contains { $0.store.servesStateResources }
    }

    /// Whose an entry is for Cmd-Shift-T (decision 1, reopen-closed.md 4).
    enum Owner: Equatable {
        /// Its tab or screen left a workspace that `window` lists.
        case window
        /// Its workspace is listed by no window (a closed workspace, a
        /// deleted group, a workspace no window shows).
        case none
        /// Another window (open or closed) lists its workspace.
        case otherWindow
    }

    /// Every kind of closed item: tabs, screens, workspaces and windows.
    static let allKinds: Set<ClosedItem.Kind> = [.tab, .screen, .workspace, .window]

    /// This install's window record id (`install/window`) of window
    /// `windowID` (`window-records-v1`), nil without an install id.
    static func recordID(window windowID: String, in services: AppServices) -> String? {
        guard let install = try? services.cloud.localDeviceID() else { return nil }
        return install + "/" + windowID
    }

    /// Who owns `entry` as seen from window `window` (a window id). The
    /// daemon names the window record a group left (the app mirrors its
    /// windows there, `WindowRecordSaver`): this window's record owns it;
    /// another open window of this app, or another Mac's window, owns it
    /// too; a window this app closed (also a `window` item itself) or no
    /// longer has owns nothing. Without a recorded window (an older or a
    /// remote daemon) the workspace's window decides.
    static func owner(of entry: Entry, window: String?, in services: AppServices) -> Owner {
        owner(of: entry, window: window, install: try? services.cloud.localDeviceID(), in: services)
    }

    /// Same, with this install's id read once. The recorded window decides only
    /// on this Mac's daemon for a window the registry has; else the workspace's
    /// window does. A window item of an unknown window is not reopenable.
    private static func owner(of entry: Entry, window: String?, install: String?, in services: AppServices) -> Owner {
        if entry.daemon.isLocal, let install, let recorded = entry.item.window, recorded.hasPrefix(install + "/") {
            let windowID = String(recorded.dropFirst(install.count + 1))
            if let known = services.windows.registry.value.window(windowID) {
                if windowID == window { return .window }
                return known.isOpen ? .otherWindow : .none
            }
            if entry.item.kind == .window { return .otherWindow }
        }
        if entry.item.kind == .window { return .otherWindow }
        guard let resource = entry.item.workspaceID, let workspace = entry.daemon.store.workspace(resourceID: resource),
              let owner = services.windows.registry.value.owner(of: workspace.id) else { return .none }
        return owner == window ? .window : .otherWindow
    }

    /// Cmd-Shift-T's item for window `window`: the newest group of any
    /// level (tab, screen, workspace, window) that left this window, else
    /// the newest one no live window owns (a closed window among them).
    /// Never a group of another live window (decision 1).
    static func newest(for window: String?, in services: AppServices) -> Entry? {
        owned(by: window, in: services).first
    }

    /// Cmd-Shift-T's items for `window`, in its order: this window's groups, then the unowned ones.
    private static func owned(by window: String?, in services: AppServices) -> [Entry] {
        let all = entries(allKinds, in: services), install = try? services.cloud.localDeviceID()
        let owners = all.map { owner(of: $0, window: window, install: install, in: services) }
        return [Owner.window, Owner.none].flatMap { wanted in zip(all, owners).filter { $0.1 == wanted }.map { $0.0 } }
    }

    /// Cmd-Shift-T (input-principles.md 1-3, audit A1): the newest item of `window` no earlier press
    /// or by-id reopen (Undo, History) took (``ClosedReopenClaims``: the store drops an item only on
    /// the daemon's event), so N presses reopen N items newest first, none twice, and a press behind
    /// an Undo of the newest reopens the next newest. With no close or press on its way, a
    /// press picks in its own turn. A close on its way (a close intent) is newer than every record,
    /// and its record reaches the store on its own stream: a press made then (or behind such a press)
    /// waits for the closes to apply and lets the daemon pick its newest item, so Cmd-W then
    /// Cmd-Shift-T reopens the tab just closed. Each press sends after the one before replied: each
    /// item goes back to its old place, right only newest first. False: nothing to reopen.
    static func reopenNewest(for window: String?, in services: AppServices) -> Bool {
        guard let undo = services.closedTabs?.undoToasts else {
            guard let entry = newest(for: window, in: services) else { return false }
            reopen(entry, services: services)
            return true
        }
        let closing = pendingCloses(in: services)
        let target: Entry?
        if closing.isEmpty, undo.reopensWaiting == 0 {
            guard let entry = take(for: window, in: services, undo) else { return false }
            target = entry
        } else {
            let left = owned(by: window, in: services).count { !undo.reopenClaims.contains($0.item.id) }
            guard left + closing.map(\.transactions.count).reduce(0, +) > undo.reopensWaiting else { return false }
            undo.reopensWaiting += 1
            target = nil
        }
        // Behind the press before it and the by-id reopens (Undo, History) made before it: their items are taken.
        let previous = undo.reopenTail, byID = Array(undo.reopenClaims.sends.values)
        // task-owner: CloseUndoToasts.reopenTail, the next press's wait; it ends with its reply
        // main-hop-allow: the person's reopen, in press order: it resumes on main only after the press and the by-id reopens before it replied and after the closes pending at the press applied (5 s at most), then sends
        let sent = Task { @MainActor [weak undo] () -> Sent? in
            _ = await previous?.value
            for reopen in byID { _ = await reopen.value }
            let result: Sent? = if let target { (entry: target, reply: await send(target, services: services)) } else {
                await sendNewest(for: window, after: closing, services: services, undo)
            }
            // Not reopened: the next request may take it again (released before that press picks).
            if let result {
                let reopened = if case .success = result.reply { true } else { false }
                undo?.reopenClaims.settle(result.entry.item.id, reopened: reopened)
            }
            return result
        }
        undo.reopenTail = sent
        // main-hop-allow: the rest of the person's reopen (userBlocking, p06 rule 2), tracked for a capturing caller: it shows what came back on main
        services.registry.track(Task { @MainActor in
            guard let sent = await sent.value else {
                // Nothing left in the history: the app's registry reopens the last closed window, as the press would have.
                if services.windows.reopenClosedWindow() { return nil }
                services.registry.refuse(RefusalStrings.noRecentlyClosedTab, quiet: true)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.noRecentlyClosedTab)
            }
            return await finish(sent.entry, sent.reply, services: services)
        })
        return true
    }

    /// A press made while closes or earlier presses were on their way, after the presses before it
    /// replied. Behind closes, once they applied (5 s at most) the daemon picks its newest group of
    /// `window` (it holds their records; the store may not yet); else the store's newest untaken one.
    private static func sendNewest(for window: String?, after closing: [PendingCloses], services: AppServices,
                                   _ undo: CloseUndoToasts?) async -> Sent? {
        defer { undo?.reopensWaiting -= 1 }
        for close in closing {
            let store = close.daemon.store, transactions = close.transactions
            _ = await Deadline(.seconds(5)).value("reopen.pending-closes") { await store.waitIntentsIdle(of: transactions) }
        }
        guard let daemon = (closing.first { $0.daemon.isLocal } ?? closing.first)?.daemon else {
            guard let undo, let entry = take(for: window, in: services, undo) else { return nil }
            return (entry, await send(entry, services: services))
        }
        guard let connection = daemon.connection else { return nil }
        let record = window.flatMap { recordID(window: $0, in: services) }
        let reply: Result<StateResourceClient.ReopenedItem, any Error>
        do {
            reply = .success(try await connection.state.reopenNewestClosed(window: record))
        } catch {
            reply = .failure(error)
        }
        switch reply {
        case .success(let reopened):
            guard let id = reopened.closedID else { return nil }
            undo?.reopenClaims.claim(id)
            // Its record, or what the reply says when the store has none yet.
            let kind: ClosedItem.Kind = reopened.window != nil ? .window : reopened.screenIDs.isEmpty ? .tab : .workspace
            let recorded = entry(id, in: services)
            // Its browser tabs' pages restore the history they closed with (cx-d0d.59), when the store has the record.
            if let recorded, daemon.isLocal { services.cache.pageRequests.closedHistories.expect(recorded.item) }
            return (recorded ?? Entry(item: ClosedItem(id: id, kind: kind), daemon: daemon), .success((connection, reopened)))
        case .failure(DaemonError.command(_, _, "resource.not_found", _, _)):
            return nil
        case .failure(let error):
            return (Entry(item: ClosedItem(id: "newest", kind: .tab), daemon: daemon), .failure(error))
        }
    }

    /// The newest item of `window` no earlier reopen took (``ClosedReopenClaims``), taken now.
    private static func take(for window: String?, in services: AppServices, _ undo: CloseUndoToasts) -> Entry? {
        guard let entry = owned(by: window, in: services).first(where: { !undo.reopenClaims.contains($0.item.id) }) else { return nil }
        undo.reopenClaims.claim(entry.item.id)
        return entry
    }

    /// The entry with id `id` on any daemon.
    static func entry(_ id: String, in services: AppServices) -> Entry? {
        entries(allKinds, in: services).first { $0.item.id == id }
    }

    /// The newest recorded delete of personal workspace group `id`, if a
    /// daemon serves one (Ungroup and Delete Group record the group).
    static func groupEntry(_ id: String, in services: AppServices) -> Entry? {
        entries([.workspace], in: services).first { $0.item.group?.id == id }
    }

    /// One daemon's pending close intents (Cmd-W, close buttons): closes whose record may not be in the store yet.
    typealias PendingCloses = (daemon: DaemonService, transactions: Set<ClientTransactionID>)

    private static func pendingCloses(in services: AppServices) -> [PendingCloses] {
        services.machines.daemons.compactMap { daemon in
            let closes = Set(daemon.store.pendingIntents.compactMap { pending -> ClientTransactionID? in
                if case .closeTabs = pending.intent { pending.transaction } else { nil }
            })
            return closes.isEmpty ? nil : (daemon, closes)
        }
    }

    /// Sends `closed.reopen` for `entry` and notes when its reply and its tabs came (`debug.filepages`).
    static func send(_ entry: Entry, services: AppServices) async -> Reply {
        let daemon = entry.daemon, item = entry.item
        guard let connection = daemon.connection else { return .failure(DaemonError.notConnected) }
        let start = ContinuousClock.now
        // Its browser tabs' pages restore the history they closed with (cx-d0d.59).
        if daemon.isLocal { services.cache.pageRequests.closedHistories.expect(item) }
        do {
            let reopened = try await connection.state.reopenClosed(item.id)
            // Where a slow restore spends its time (nxdog52: the first Cmd-Z took over 2 s).
            let reply = start.duration(to: .now)
            services.closedTabs?.undoToasts.watchReopen(id: item.id, tabs: reopened.tabIDs, reply: reply, since: start,
                                                        daemon: daemon, connection: connection)
            return .success((connection, reopened))
        } catch {
            return .failure(error)
        }
    }

    /// Shows what `reply` reopened of `entry`, or why it did not.
    static func finish(_ entry: Entry, _ reply: Reply, services: AppServices) async -> ActionWorkFailure? {
        let daemon = entry.daemon, item = entry.item
        let connection: DaemonConnection, reopened: StateResourceClient.ReopenedItem
        switch reply {
        case .success(let value):
            connection = value.connection
            reopened = value.item
        case .failure(DaemonError.notConnected):
            return ActionWorkFailure(MiscHandlerStrings.daemonOffline)
        case .failure(let error):
            daemon.logger.error("closed.reopen failed: \(String(describing: error), privacy: .public)")
            services.cache.pageRequests.closedHistories.drop(item)
            if item.kind == .workspace, item.group == nil,
               case DaemonError.command(_, _, let code, _, _) = error, code == "resource.not_found" {
                services.registry.refuse(RefusalStrings.noRecentlyClosedWorkspace)
                return ActionWorkFailure(refusal: .unavailable, reason: RefusalStrings.noRecentlyClosedWorkspace)
            }
            return "closed.reopen: \(error)"
        }
        // A reopened workspace group forms again in the sidebar; no window changes what it shows.
        if item.group != nil { return nil }
        // A closed window: the app shows it again with the workspaces it kept.
        if item.kind == .window {
            let windowID = reopened.window?.split(separator: "/", maxSplits: 1).last.map(String.init)
            if let windowID, services.windows.reopenClosedWindow(id: windowID) { return nil }
            let reason = RefusalStrings.noWindow(windowID ?? item.id)
            services.registry.refuse(reason)
            return ActionWorkFailure(refusal: .unavailable, reason: reason)
        }
        let pane = item.paneID.flatMap { id in
            daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.resourceID == id }
        }
        if item.kind == .tab, let tab = reopened.tabIDs.first, let pane, let controller = services.paneController(for: pane) {
            controller.selectWhenReported(tab: tab.rawValue)
            return nil
        }
        await daemon.appliedThroughReply(on: connection, after: "reopen closed")
        if item.kind == .workspace {
            if let id = reopened.workspaceID,
               let workspace = await daemon.store.workspace(afterReopen: id) {
                services.windows.reveal(workspaceID: workspace)
                return nil
            } else {
                let reason = RefusalStrings.noWorkspace(reopened.workspaceID?.rawValue ?? item.id)
                daemon.logger.error("closed.reopen timed out waiting for its workspace: \(item.id, privacy: .public)")
                services.registry.refuse(reason)
                return ActionWorkFailure(reason, mayHaveApplied: true)
            }
        }
        show(reopened, kind: item.kind, daemon: daemon, services: services)
        return nil
    }

    /// Shows a reopened item once the store has it.
    static func show(_ reopened: StateResourceClient.ReopenedItem, kind: ClosedItem.Kind, daemon: DaemonService,
                     services: AppServices) {
        guard let workspaceID = reopened.workspaceID, let workspace = daemon.store.workspace(resourceID: workspaceID),
              let window = services.windows.active else { return }
        services.windows.show(workspaceID: workspace.id, in: window.state)
        switch kind {
        case .screen:
            guard let screen = workspace.screens.first(where: { $0.resourceID == reopened.screenIDs.first }),
                  let content = window.content else { return }
            ScreenCommands.select(LayoutScreenID(screen.id), in: content)
        case .tab:
            guard let tab = reopened.tabIDs.first,
                  let pane = workspace.screens.flatMap(\.panes).first(where: { $0.tabs.contains { $0.resourceID == tab } }),
                  let controller = services.paneController(for: pane) else { return }
            controller.selectWhenReported(tab: tab.rawValue)
        case .workspace, .window:
            break
        }
    }
}
