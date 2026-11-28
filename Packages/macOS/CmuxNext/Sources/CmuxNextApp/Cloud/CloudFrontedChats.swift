import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextAppCore
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextDaemonService
import enum CmuxNextHomeEngine.AgentPaneHostKind
import CmuxNextTabs
import Foundation
import Observation

/// A Cloud chat started from this Mac's tab shows in that tab, in place (cmux#47677). The chat runs in its own
/// workspace on the Cloud machine (a workspace never mixes machines), but that workspace stays out of every
/// window: no new row, nothing at the sidebar's end, no switch. The Mac tab keeps its pane, its row and its place
/// in the strip, and draws the Cloud tab's page (``AgentTabStore/view(for:machine:known:)``) and title.
///
/// Closing the Mac tab ends the Cloud chat's workspace (``closeCloud``); the Cloud tab going (its machine deleted)
/// lets the Mac tab show its own page again (``reshow``). Kept across relaunches in `defaults`.
@MainActor
@Observable
final class CloudFrontedChats {
    typealias Front = AgentTabCloudFront

    private struct Entry: Codable { let machine: String; let key: String; let front: Front }

    static let defaultsKey = "cmux.cloud.frontedChats"

    private var fronts: [AgentTabKey: Front] = [:]
    /// Workspaces a start is making for a Mac tab, held before they list (``hold(_:)``).
    private var making: Set<String> = []
    /// Where the fronts are kept; nil keeps them in memory (tests).
    @ObservationIgnored var defaults: @MainActor () -> UserDefaults? = { nil }
    /// Ends a Cloud chat whose Mac tab closed: its workspace on its machine.
    @ObservationIgnored var closeCloud: @MainActor (Front) -> Void = { _ in }
    /// Draws Mac tab `mac` again (its panes' `showSelected`) once Cloud tab `cloud`, the chat it showed, went.
    @ObservationIgnored var reshow: @MainActor (_ mac: AgentTabKey, _ cloud: AgentTabKey) -> Void = { _, _ in }

    var isEmpty: Bool { fronts.isEmpty && making.isEmpty }

    /// The Cloud workspaces no window may take: each front's, and each one a start is making for a Mac tab.
    var workspaceIDs: Set<String> { making.union(fronts.values.map(\.workspace)) }

    /// The Cloud chat Mac tab `mac` shows, if it shows one.
    func front(of mac: AgentTabKey) -> Front? { fronts.isEmpty ? nil : fronts[mac] }

    /// The Mac tab that shows Cloud tab `cloud`.
    func mac(showing cloud: AgentTabKey) -> AgentTabKey? { fronts.first { $0.value.tab == cloud }?.key }

    /// The Mac tab that shows the chat of Cloud workspace `workspace`.
    func mac(showingWorkspace workspace: String) -> AgentTabKey? { fronts.first { $0.value.workspace == workspace }?.key }

    /// Holds `workspace` out of every window while a start makes it. A start that fails keeps it held: its retry
    /// opens the same workspace (``CloudMachineWorkspace/chatKey(tabKey:)``), which never shows as a row.
    func hold(_ workspace: String) { making.insert(workspace) }

    /// Mac tab `mac` shows `front` from now on.
    func front(_ mac: AgentTabKey, with front: Front) {
        making.remove(front.workspace)
        fronts[mac] = front
        persist()
    }

    /// A tab went (no store lists it): a Mac tab's Cloud chat ends with it; a Cloud tab's Mac tab shows its own page.
    func gone(_ tab: AgentTabKey) {
        if let front = fronts.removeValue(forKey: tab) {
            persist()
            closeCloud(front)
        } else if let mac = mac(showing: tab) {
            fronts[mac] = nil
            persist()
            reshow(mac, tab)
        }
    }

    /// The fronts kept by the last run.
    func restore() {
        guard let data = defaults()?.data(forKey: Self.defaultsKey), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return } // main-actor-ok: one small list (an entry per agent tab with a Cloud front), read once at launch.
        for entry in entries { fronts[AgentTabKey(machine: entry.machine, key: entry.key)] = entry.front }
    }

    private func persist() {
        guard let defaults = defaults() else { return }
        let entries = fronts.map { Entry(machine: $0.key.machine, key: $0.key.key, front: $0.value) }.sorted { ($0.machine, $0.key) < ($1.machine, $1.key) }
        if entries.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) } else if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

extension CloudFrontedChats {
    /// `tabs`' fronts, wired to `services`: kept in the app's defaults, a closed Mac tab's Cloud workspace closed on its
    /// machine, and a Mac tab whose Cloud tab went drawn again in each pane that lists it.
    static func wire(_ tabs: AgentTabStore, services: AppServices) {
        let fronts = tabs.frontedChats
        fronts.defaults = { [weak services] in services?.cloud.move.ledger }
        fronts.closeCloud = { [weak services] front in
            guard let connection = services?.machines.session(front.machine)?.daemon.connection else { return }
            // task-owner: one close request; the workspace's row never showed, so nothing waits on it
            Task { _ = try? await connection.closeWorkspace(WorkspaceKey(rawValue: front.workspace)) }
        }
        // Its new page says the Cloud chat ended, the start's prompt back in its composer: never a blank chat (cmux#55066).
        // After the release that dropped the front: a show now would make the Mac tab's page inside that release.
        fronts.reshow = { [weak services] mac, cloud in
            if let tabs = services?.agentTabs, let seed = AgentPaneCloudStarted.endedSeed(tabs.pageChats.cloudStarted.removeValue(forKey: cloud), machine: services?.machines.session(cloud.machine)?.machine.title) { tabs.seeds[mac] = seed }
            // task-owner: one main hop; it shows nothing once the app's services went
            Task { @MainActor [weak services] in if let services { showSelected(mac.key, services: services) } }
        }
        fronts.restore()
    }

    /// The page of Mac tab `mac` while it shows Cloud chat `front` in place: the Cloud tab's own page. The Mac tab
    /// stays tracked in its store, so its close ends the chat (``AgentTabStore/release(_:machine:)``).
    static func view(of mac: AgentTabKey, _ front: Front, in tabs: AgentTabStore) -> AgentPaneView? {
        if tabs.tabStores[mac] == nil, let (_, store) = tabs.record(for: mac) { tabs.track(mac.key, in: store, machine: mac.machine) }
        return tabs.view(for: front.key, machine: front.machine)
    }

    /// A show of the Cloud workspace whose chat Mac tab `mac` shows in place: the Mac tab's workspace shows, with that
    /// tab selected. The Cloud workspace never joins a window or the sidebar.
    static func show(_ mac: AgentTabKey, in state: WindowState, from origin: ShowOrigin, windows: WindowManager) {
        let services = windows.services
        guard let workspace = services.workspaceID(ofTab: mac.key), !services.agentTabs.frontedChats.workspaceIDs.contains(workspace) else { return }
        windows.show(workspaceID: workspace, in: state, from: origin)
        services.agentTabs.selectInPaneScoped(mac)
    }

    /// Draws tab `key` again in each pane whose strip lists it.
    static func showSelected(_ key: String, services: AppServices) {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] { _ = pane.showsAgain(key) }
        }
    }
}

extension CloudFrontedChats {
    /// The Cloud tab Mac tab `tab` shows in place, as its machine's store lists it (nil once that machine is gone).
    static func shown(by tab: TabModel, services: AppServices) -> TabModel? {
        let tabs = services.agentTabs
        guard !tabs.frontedChats.isEmpty, let machine = tabs.daemonListing(tab)?.machineID,
              let front = tabs.frontedChats.front(of: AgentTabKey(machine: machine, key: tab.id)) else { return nil }
        return services.machines.session(front.machine)?.daemon.store.tab(id: front.key)
    }
}

extension CloudStartChat {
    /// This Mac's tab `tab`, when a Cloud start from it turns it into the chat in place, with the chat's `workspace`
    /// held out of every window from now; nil for a tab of another machine, whose start opens the chat's workspace.
    @MainActor static func frontsInPlace(_ tab: TabModel, workspace: String, services: AppServices) -> AgentTabKey? {
        guard let daemon = services.agentTabs.daemonListing(tab), daemon.isLocal else { return nil }
        services.agentTabs.frontedChats.hold(workspace)
        return AgentTabKey(machine: daemon.machineID, key: tab.id)
    }

    /// Mac tab `mac` shows the started chat `front` from now on: its own page goes, and each pane listing it draws the chat's.
    @MainActor static func front(_ mac: AgentTabKey, with front: CloudFrontedChats.Front, services: AppServices) {
        services.agentTabs.release(mac.key, machine: mac.machine)
        services.agentTabs.frontedChats.front(mac, with: front)
        CloudFrontedChats.showSelected(mac.key, services: services)
    }
}

/// A Cloud chat's Terminal and Browser on its Cloud machine (``CloudChatToolRoute``, cmux#55413).
extension CloudFrontedChats {
    /// Opens tool `kind` of chat tab `chat` on its Cloud machine: true once routed there (a refusal says why), nil
    /// for a chat that is not a Cloud machine's or a tool its own pane opens on the machine already.
    static func openTool(_ kind: RightColumnPlacement.Kind, chat: AgentTabKey, cwd: String?, services: AppServices) -> Bool? {
        guard let session = services.machines.session(chat.machine) else { return nil }
        let fronts = services.agentTabs.frontedChats, mac = fronts.mac(showing: chat), context = AppActionContext(services: services)
        switch CloudChatToolRoute.resolve(kind == .browser ? .browser : kind == .terminal ? .terminal : .other, onCloud: true, shownOnThisMac: mac != nil) {
        case .asLocal:
            return nil
        case .desktopBeside, .desktopWorkspace:
            // A machine with no desktop: a chat in its machine's workspace keeps its pane's browser tab (which runs on the
            // machine where it has a browser host); a Mac tab showing the chat says why, never a tab on this Mac.
            guard (try? CloudHandlers.desktopRecord(session)) != nil else {
                guard mac != nil else { return nil }
                services.registry.refuse(CloudStrings.desktopUnavailable(session.machine.title))
                return true
            }
            // A Mac tab in no window opens the desktop as Open Desktop does, in its own workspace.
            if let mac, openDesktop(session, beside: mac, services: services) { return true }
            do { try CloudHandlers.openDesktop(session, context) } catch { services.registry.refuse(CloudStrings.errorText(error)) }
        case .machineTerminal:
            // Never in the chat's own workspace, which no window shows.
            let skipping = fronts.workspaceIDs
            CloudHandlers.runTracked("open Cloud chat terminal", context) {
                let anchor = try await CloudHandlers.terminalAnchor(on: session, context, skipping: skipping)
                guard let connection = session.daemon.connection else { throw ActionFailure(message: CloudStrings.notConnected) }
                let created = try await connection.newTab(in: anchor.pane.handle, options: SpawnOptions(cwd: cwd, workspace: anchor.key))
                CloudHandlers.reveal(created.surface, in: anchor.pane, workspaceID: anchor.id, context)
            }
        }
        return true
    }

    /// Where chat tab `chat`'s header Files opens: this Mac's tree for a chat here; for a Cloud or SSH chat, its
    /// machine's tree, read through that machine's daemon (never this Mac's folder), beside the Mac tab that shows the
    /// chat in place when one does. Nil when the chat names no machine this Mac reaches.
    static func filesPlace(_ chat: AgentTabKey, services: AppServices) -> (link: AgentPaneGitLink, machine: DaemonService?, beside: String)? {
        guard let link = services.agentTabs.gitLinkScoped?(chat),
              let (tab, _) = chat.machine.isEmpty ? services.locateTab(chat.key) : services.locateTab(chat.key, onMachine: chat.machine) else { return nil }
        // This Mac's tree only for a chat this Mac's acpmux runs (any of its install hosts), listed here: never a chat whose
        // folder is another host's path.
        if link === services.agentGit.local {
            guard services.machines.daemon(forTab: tab).isLocal, let record = tab.agentSession, services.agentTabs.hostKind(record, listedHere: true) == .local else { return nil }
            return (link, nil, chat.key)
        }
        guard let daemon = try? services.machines.agentDaemon(forTab: tab) else { return nil }
        return (link, daemon, services.agentTabs.frontedChats.mac(showing: chat)?.key ?? chat.key)
    }

    /// The machine's desktop in a browser tab beside Mac tab `mac`, where the header's Browser opens on a chat of this
    /// Mac (``RightColumnPlacement``). A person clicked it, so it connects without asking, as Open Desktop's tab does:
    /// the approval goes on the exact tab this open made, once listed. False when the Mac tab is in no window.
    static func openDesktop(_ session: CloudMachineSession, beside mac: AgentTabKey, services: AppServices) -> Bool {
        guard let record = try? CloudHandlers.desktopRecord(session), let (_, pane) = services.locateTab(mac.key, onMachine: mac.machine),
              let source = services.paneController(for: pane) else { return false }
        let url = record.url, scope = ActionRunScope.current, cache = services.cache
        return services.linkOpener.open(from: source, besideChat: true, kind: .browser, opening: .tool, split: services.linkOpener.browserSplit(nil)) { target, placed in
            let store = target.daemon.store
            return target.newBrowserTab(url: url, placementOwner: placed != nil) { surface in
                placed?(surface)
                // task-owner: one wait for the new tab's mirror, bounded by CloudWait.holds's 10 s; it then records one approval.
                Task { [weak cache] in
                    guard await CloudWait.holds(within: .seconds(10), until: { store.tab(surface: surface) != nil }), let id = store.tab(surface: surface)?.id else { return }
                    cache?.personOpenedRemoteView(id, url: url, scope: scope)
                }
            }
        }
    }
}
