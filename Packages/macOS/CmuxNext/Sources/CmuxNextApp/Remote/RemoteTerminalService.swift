import AppKit
import CmuxNextCloud
import CmuxNextDaemon
import CmuxNextTerminal
import Observation

/// Remote-terminal tabs (plans/cmux-next/data-model.md 1.2b, 1.4, 1.5): a
/// tab in one session's layout whose terminal runs on another session.
///
/// - Mounting: the tab's surface attaches over the terminal's own session
///   by its public id (`TabContentCache.remoteTerminal`), with no tab there.
/// - Unavailable: while that session is not connected (or never was on this
///   Mac) the pane shows `RemoteTerminalPlaceholderView` with the last
///   screen the home session saved; the reference is never dropped.
/// - Snapshot: when the session goes away, the last screen is read from the
///   local Ghostty mirror and saved on the tab's own session (bounded to
///   64 KiB); also before quit. Event driven, never polled.
/// - Title: the live terminal's title is saved on the tab when it changes.
@MainActor
final class RemoteTerminalService {
    unowned let services: AppServices
    /// `term_` ids of terminals by `<session>#<terminal>`, learned from a
    /// move, a new terminal, or `set-terminal-keep`.
    private var resources: [String: ResourceID] = [:]
    private var resolving: Set<String> = []
    /// Terminals whose session could not name them (older cmux-tui).
    private var unresolvable: Set<String> = []
    private var placeholders: [String: RemoteTerminalPlaceholderView] = [:]
    /// Live surfaces: the reference and the tab's own session, by tab id.
    private var live: [String: (ref: RemoteTerminalRef, home: DaemonService)] = [:]
    private var titleTasks: [String: Task<Void, Never>] = [:]
    private var availability: [String: String] = [:]
    private var observation: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    static func key(_ ref: RemoteTerminalRef) -> String { "\(ref.sessionID)#\(ref.terminalID.rawValue)" }

    // MARK: Availability

    /// Re-shows remote-terminal tabs whenever a session connects, drops or
    /// restarts (one Observation of every daemon's connection and generation).
    func start() {
        let machines = services.machines
        observation = Task { [weak self] in
            let tokens = Observations { () -> [String: String] in
                var map: [String: String] = [:]
                for daemon in machines.daemons {
                    guard let session = daemon.identity?.sessionID else { continue }
                    map[session] = "\(daemon.connection != nil)#\(daemon.store.isLoaded)#\(daemon.store.generation?.rawValue ?? "")"
                }
                return map
            }
            for await map in tokens {
                self?.availabilityChanged(map)
            }
        }
    }

    private func availabilityChanged(_ map: [String: String]) {
        let changed = Set(map.keys).union(availability.keys).filter { map[$0] != availability[$0] }
        availability = map
        guard !changed.isEmpty else { return }
        for (tabID, entry) in live where changed.contains(entry.ref.sessionID) && !isAvailable(entry.ref.sessionID) {
            saveSnapshot(tabID: tabID)
            services.cache.discardTerminal(tabID)
            live[tabID] = nil
            titleTasks.removeValue(forKey: tabID)?.cancel()
        }
        reshow { changed.contains($0.sessionID) }
    }

    private func isAvailable(_ session: String) -> Bool {
        guard let daemon = services.machines.daemon(session: session) else { return false }
        return daemon.connection != nil && daemon.store.isLoaded && daemon.store.generation != nil
    }

    /// Asks every pane showing a remote-terminal tab that matches to show its selection again.
    private func reshow(_ matches: (RemoteTerminalRef) -> Bool) {
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard let tab = pane.selectedTab, tab.kind == .remoteTerminal, let ref = tab.remote, matches(ref) else { continue }
                services.presentation.setNeedsShowSelected(pane)
            }
        }
    }

    // MARK: Content

    /// The live terminal when its session is attached, else the placeholder.
    func content(for tab: TabModel, home: DaemonService) -> TabContent {
        guard let ref = tab.remote else { return .placeholder(placeholder(for: tab, home: home, ref: nil)) }
        if isAvailable(ref.sessionID), let daemon = services.machines.daemon(session: ref.sessionID) {
            if let resource = resource(for: ref, on: daemon) {
                if let entry = services.cache.remoteTerminal(for: tab, ref: ref, resource: resource, daemon: daemon, size: tab.size) {
                    live[tab.id] = (ref, home)
                    placeholders[tab.id] = nil
                    followTitle(of: entry, tab: tab, home: home)
                    return .terminal(entry)
                }
            } else {
                resolve(ref, on: daemon)
            }
        }
        return .placeholder(placeholder(for: tab, home: home, ref: ref))
    }

    /// The placeholder tab `key` shows now, if any.
    func existingPlaceholder(_ key: String) -> RemoteTerminalPlaceholderView? { placeholders[key] }

    /// The machine name on a remote-terminal tab (the subtle machine badge).
    func badge(for tab: TabModel) -> String? {
        guard let ref = tab.remote else { return nil }
        return machineName(ref)
    }

    func machineName(_ ref: RemoteTerminalRef) -> String {
        if let daemon = services.machines.daemon(session: ref.sessionID) {
            if daemon.isLocal { return daemon.identity?.machineName ?? MacName.kernelHostName() }
            return services.machines.machineBadge(daemon.machineID) ?? daemon.identity?.machineName ?? ref.sessionName
        }
        return ref.sessionName
    }

    func resource(for ref: RemoteTerminalRef, on daemon: DaemonService) -> ResourceID? {
        if let known = resources[Self.key(ref)] { return known }
        return daemon.store.tab(terminal: ref.terminalID)?.terminalResourceID
    }

    /// Learns a terminal's public id from its session (`set-terminal-keep`,
    /// which also keeps it: its only view is in another layout).
    private func resolve(_ ref: RemoteTerminalRef, on daemon: DaemonService) {
        let key = Self.key(ref)
        guard !resolving.contains(key), !unresolvable.contains(key), let connection = daemon.connection else { return }
        resolving.insert(key)
        // task-owner: one bounded keep request; `resolving` dedupes it and a gone service drops the result
        Task { [weak self] in
            let resource = try? await connection.keepTerminal(ref.terminalID)
            guard let self else { return }
            resolving.remove(key)
            if let resource {
                remember(ref, resource: resource)
            } else {
                unresolvable.insert(key)
                services.registry.refuse(RemoteStrings.machineHasNoTerminal)
            }
            reshow { Self.key($0) == key }
        }
    }

    func remember(_ ref: RemoteTerminalRef, resource: ResourceID) {
        resources[Self.key(ref)] = resource
        unresolvable.remove(Self.key(ref))
    }

    private func placeholder(for tab: TabModel, home: DaemonService, ref: RemoteTerminalRef?) -> RemoteTerminalPlaceholderView {
        let view: RemoteTerminalPlaceholderView
        if let existing = placeholders[tab.id] {
            view = existing
        } else {
            view = RemoteTerminalPlaceholderView(frame: .zero)
            placeholders[tab.id] = view
            loadSnapshot(into: view, surface: tab.surface, home: home)
        }
        let name = ref.map(machineName) ?? tab.displayTitle
        let daemon = ref.flatMap { services.machines.daemon(session: $0.sessionID) }
        view.onConnect = daemon.flatMap { connector(for: $0) }
        let state: RemoteTerminalPlaceholderView.State = switch daemon?.store.connectionState {
        case nil: .unknown
        case .connecting?, .connected?: .reconnecting
        case .disconnected?, .failed?: .offline
        }
        view.show(machine: name, state: state, snapshot: view.snapshotText == RemoteStrings.placeholderNoSnapshot ? nil : view.snapshotText)
        return view
    }

    private func connector(for daemon: DaemonService) -> (() -> Void)? {
        let machines = services.machines
        if let ssh = machines.sshSession(daemon.machineID) {
            let service = services.ssh
            return { service?.reconnect(ssh) }
        }
        if let cloud = machines.session(daemon.machineID) { return { cloud.connect(origin: .user) } }
        return nil
    }

    private func loadSnapshot(into view: RemoteTerminalPlaceholderView, surface: SurfaceID, home: DaemonService) {
        guard let connection = home.connection, home.supports(DaemonCapabilities.shared.remoteTerminalTabs) else { return }
        // task-owner: one bounded read into a weak view; a closed tab drops the result
        Task { [weak view] in
            guard let text = try? await connection.remoteTerminalSnapshot(surface) else { return }
            view?.setSnapshot(text)
        }
    }

    // MARK: Snapshots and titles

    /// Saves the last screen of a live remote terminal on its tab's session.
    @discardableResult
    private func saveSnapshot(tabID: String) -> Task<Void, Never>? {
        guard let (_, home) = live[tabID], let entry = services.cache.existingTerminal(tabID),
              let text = entry.session.surfaceView.viewportText(), !text.isEmpty,
              let tab = home.store.tab(id: tabID), let connection = home.connection else { return nil }
        let surface = tab.surface
        let title = entry.session.model.title
        placeholders[tabID]?.setSnapshot(text)
        return Task {
            _ = try? await connection.updateRemoteTerminalTab(surface, title: title.isEmpty ? nil : title, snapshot: text)
        }
    }

    /// Before quit: every live remote terminal's screen, so the placeholder
    /// after relaunch shows it while the machine reconnects.
    func saveSnapshots() async {
        let tasks = live.keys.compactMap { saveSnapshot(tabID: $0) }
        for task in tasks { await task.value }
    }

    /// Saves the live terminal's title on the tab while it is attached.
    private func followTitle(of entry: TerminalEntry, tab: TabModel, home: DaemonService) {
        guard titleTasks[tab.id] == nil else { return }
        let model = entry.session.model
        let tabID = tab.id
        titleTasks[tab.id] = Task { [weak self, weak home] in
            var last = ""
            for await title in Observations({ model.title }) {
                guard !title.isEmpty, title != last, let home, let connection = home.connection,
                      let surface = home.store.tab(id: tabID)?.surface else { continue }
                last = title
                _ = try? await connection.updateRemoteTerminalTab(surface, title: title)
                if self == nil { return }
            }
        }
    }

    /// The user closed remote-terminal `tab`. When the terminal has no tab
    /// on its own session this was its only view, so the terminal ends
    /// (`close-terminal`; a remote-terminal tab has no Reopen Closed Tab,
    /// and a daemon may not reap). When it also has a tab there, it only
    /// stops being kept. A session that is not connected keeps the terminal
    /// until it is closed there.
    func viewClosed(_ tab: TabModel) {
        forget(tabID: tab.id)
        services.cache.discardTerminal(tab.id)
        guard let ref = tab.remote, let daemon = services.machines.daemon(session: ref.sessionID),
              let connection = daemon.connection else { return }
        let terminal = ref.terminalID
        let placed = daemon.store.tab(terminal: terminal) != nil
        // task-owner: fire-and-forget end of a terminal whose only view closed
        Task {
            if placed {
                _ = try? await connection.setTerminalKeep(.terminal(terminal), keep: false)
            } else {
                try? await connection.closeTerminal(terminal)
            }
        }
    }

    /// A workspace is closing: each remote-terminal tab in it was its
    /// terminal's only view.
    func workspaceClosing(_ workspace: WorkspaceModel) {
        for tab in workspace.screens.flatMap(\.panes).flatMap(\.tabs) where tab.kind == .remoteTerminal { viewClosed(tab) }
    }

    /// The tab closed or moved away: stop following it.
    func forget(tabID: String) {
        live[tabID] = nil
        placeholders[tabID] = nil
        titleTasks.removeValue(forKey: tabID)?.cancel()
    }
}
