import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowserHistory
import CmuxNextCompat
import CmuxNextDaemon
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
    struct Entry {
        var item: ClosedItem
        var daemon: DaemonService
    }

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
        let all = entries(allKinds, in: services), install = try? services.cloud.localDeviceID()
        return all.first { owner(of: $0, window: window, install: install, in: services) == .window }
            ?? all.first { owner(of: $0, window: window, install: install, in: services) == .none }
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

    /// Reopens `entry` on its daemon and shows it: a tab selected in its
    /// pane, a screen selected in its workspace, a workspace in the active
    /// window. The failure (if any) is the tracked work's result.
    static func reopen(_ entry: Entry, services: AppServices) {
        let daemon = entry.daemon, item = entry.item
        let pane = item.paneID.flatMap { id in
            daemon.store.workspaces.lazy.flatMap(\.screens).flatMap(\.panes).first { $0.resourceID == id }
        }
        let clock = ContinuousClock(), start = clock.now
        // Its browser tabs' pages restore the history they closed with (cx-d0d.59).
        if daemon.isLocal { services.cache.pageRequests.closedHistories.expect(item) }
        services.registry.track(Task { @MainActor in
            guard let connection = daemon.connection else { return ActionWorkFailure(MiscHandlerStrings.daemonOffline) }
            let reopened: StateResourceClient.ReopenedItem
            do {
                reopened = try await connection.state.reopenClosed(item.id)
                // Where a slow restore spends its time (nxdog52: the first Cmd-Z took over 2 s).
                let reply = start.duration(to: clock.now)
                let tabs = reopened.tabIDs
                let undo = services.closedTabs?.undoToasts
                undo?.noteReopen(id: item.id, tabs: tabs.map(\.rawValue), reply: reply)
                // task-owner: CloseUndoToasts.reopenWatch (the next reopen cancels it); event-driven
                undo?.reopenWatch?.cancel()
                undo?.reopenWatch = Task { @MainActor [weak undo] in
                    await daemon.appliedThroughReply(on: connection, after: "reopen closed")
                    let inStore = { tabs.allSatisfy { id in daemon.store.workspaces.contains { $0.screens.contains { $0.panes.contains { $0.tabs.contains { $0.resourceID == id } } } } } }
                    undo?.noteReopenApplied(start.duration(to: clock.now), tabsInStore: inStore())
                    // When the reopened tabs reach the store (nxdog54: the first restore only after another event).
                    for await present in ObservationStream({ inStore() }) where present {
                        undo?.noteReopenTabsArrived(start.duration(to: clock.now))
                        return
                    }
                }
            } catch {
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
            if item.kind == .tab, let tab = reopened.tabIDs.first, let pane, let controller = services.paneController(for: pane) {
                controller.selectWhenReported(tab: tab.rawValue)
                return nil
            }
            await daemon.appliedThroughReply(on: connection, after: "reopen closed")
            if item.kind == .workspace {
                if let id = reopened.workspaceID,
                   let workspace = await daemon.store.workspace(afterReopen: id, clock: daemon.reopenClock) {
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
        })
    }

    /// A deleted `window` item of this app: its closed window lets its
    /// workspaces go (nothing could reopen them otherwise).
    private static func releaseWindow(of item: ClosedItem, daemon: DaemonService, services: AppServices) {
        guard item.kind == .window, daemon.isLocal, let recorded = item.window,
              let install = try? services.cloud.localDeviceID(), recorded.hasPrefix(install + "/") else { return }
        services.windows.releaseClosedWindow(id: String(recorded.dropFirst(install.count + 1)))
    }

    /// Sends the agent-home folders of deleted closed workspaces (the
    /// daemon moved them to `.trash-pending`, cx-gzh.9.2) to the Trash, off
    /// the main thread. At launch and after each delete or clear.
    static func emptyAgentHomeTrash() { AgentHome.emptyStandardTrashPendingInBackground() }

    /// Deletes `entry` for good on its daemon (History's Remove, Search
    /// Tabs' forget): it cannot be reopened any more.
    static func delete(_ entry: Entry, services: AppServices) {
        let daemon = entry.daemon, id = entry.item.id
        releaseWindow(of: entry.item, daemon: daemon, services: services)
        services.registry.track(Task { @MainActor in
            guard let connection = daemon.connection else { return ActionWorkFailure(MiscHandlerStrings.daemonOffline) }
            do {
                try await connection.state.deleteClosed(id)
                if daemon.isLocal { emptyAgentHomeTrash() }
                return nil
            } catch DaemonError.command(_, _, let code, _, _) where code == "resource.not_found" {
                // Already gone (a second Remove, or a reopen that ran first): the goal holds.
                return nil
            } catch {
                daemon.logger.error("closed.delete failed: \(String(describing: error), privacy: .public)")
                return "closed.delete: \(error)"
            }
        })
    }

    /// Clears every connected daemon's closed history: the groups closed at
    /// or after `since`, every group for nil (Clear History). `since` is this
    /// Mac's clock; a remote daemon with a skewed clock clears a range off by
    /// that skew.
    static func clear(since: Date?, services: AppServices) {
        let sinceMs = since.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) }
        for entry in entries([.window], in: services) where sinceMs.map({ entry.item.closedAtMs >= $0 }) ?? true {
            releaseWindow(of: entry.item, daemon: entry.daemon, services: services)
        }
        for daemon in services.machines.daemons where daemon.store.servesStateResources {
            services.registry.track(Task { @MainActor in
                guard let connection = daemon.connection else { return ActionWorkFailure(MiscHandlerStrings.daemonOffline) }
                do {
                    try await connection.state.deleteAllClosed(sinceMs: sinceMs)
                    if daemon.isLocal { emptyAgentHomeTrash() }
                    return nil
                } catch {
                    daemon.logger.error("closed.delete all failed: \(String(describing: error), privacy: .public)")
                    return "closed.delete: \(error)"
                }
            })
        }
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
