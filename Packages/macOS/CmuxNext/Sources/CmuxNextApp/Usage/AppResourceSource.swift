import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextMemory
import CmuxNextPages
import CmuxNextResources
import CmuxNextTerminal
import CmuxNextWakeups
import Darwin
import Foundation

/// Samples the processes behind tabs for the hover cards and `resources`
/// . Runs only when asked:
///
/// - Terminal tabs: the daemon that owns the terminal reports its process
///   tree and terminal host (`terminal-resources`, computed on request),
///   plus an estimate of the mounted Ghostty surface.
/// - Chromium tabs: the renderers that host the tab's frames (renderer
///   client ids from CEF, matched to helper processes by their
///   `--renderer-client-id`). GPU, network, utility and extension
///   renderers are shared, never a tab's; so is a renderer that also hosts
///   another page's frames, for one tab's card.
/// - WebKit tabs and agent chats: the web view's WebContent process.
/// - The app process is shared (chrome, Ghostty, Chromium's browser process).
///
/// Resolution reads the main-actor model; process counters are read off
/// the main actor; daemon requests are async with a 1 s deadline.
@MainActor
final class AppResourceSource: ResourceSampleSource {
    private unowned let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    /// A terminal whose numbers come from its daemon.
    private struct TerminalQuery {
        var tabID: String
        var surface: SurfaceID
    }

    private struct DaemonQuery {
        var host: String
        var connection: DaemonConnection?
        var supported: Bool
        var terminals: [TerminalQuery]
    }

    func sample(_ target: ResourceTarget) async -> ResourceSampleSet {
        let resolved = resolve(target)
        var tabs = resolved.tabs
        var tabIndex: [String: Int] = [:]
        tabIndex.reserveCapacity(tabs.count)
        for (index, tab) in tabs.enumerated() { tabIndex[tab.tabID] = index }
        var localPIDs = Set<Int32>([getpid()])
        var shared: [SharedProcess] = []
        if resolved.includesAppShare { shared.append(SharedProcess(key: ProcessKey(pid: getpid()), role: .app)) }

        // Chromium: map renderer client ids to helper processes.
        let chromiumTabs = tabs.indices.filter { resolved.rendererClients[tabs[$0].tabID] != nil }
        if !chromiumTabs.isEmpty {
            let helpers = await Self.chromiumHelpers()
            var byClient: [Int32: Int32] = [:]
            for helper in helpers {
                switch helper.kind {
                case .renderer(let client): byClient[client] = helper.pid
                case .gpu: shared.append(SharedProcess(key: ProcessKey(pid: helper.pid), role: .gpu))
                case .network: shared.append(SharedProcess(key: ProcessKey(pid: helper.pid), role: .network))
                case .utility: shared.append(SharedProcess(key: ProcessKey(pid: helper.pid), role: .utility))
                case .extensionRenderer: shared.append(SharedProcess(key: ProcessKey(pid: helper.pid), role: .extensions))
                case .other: break
                }
            }
            let foreign = Set(resolved.foreignRendererClients.compactMap { byClient[$0] })
            for index in chromiumTabs {
                let clients = resolved.rendererClients[tabs[index].tabID] ?? []
                tabs[index].processes = clients.compactMap { byClient[$0] }.filter { !foreign.contains($0) }.map { ProcessKey(pid: $0) }
            }
            if !resolved.includesAppShare { shared.removeAll() }
        }
        for tab in tabs where tab.kind != .terminal { localPIDs.formUnion(tab.processes.map(\.pid)) }
        localPIDs.formUnion(shared.map(\.key.pid))

        var samples = await Self.sampleLocal(Array(localPIDs))

        // Terminals: one request per daemon.
        for query in resolved.daemons {
            let request = TerminalResourcesRequest(surfaces: query.terminals.map(\.surface))
            guard query.supported, let connection = query.connection,
                  let response = try? await connection.request(request, timeout: .seconds(1)) else {
                for terminal in query.terminals {
                    if let index = tabIndex[terminal.tabID] { tabs[index].available = false }
                }
                continue
            }
            let bySurface = Dictionary(response.terminals.map { ($0.surface, $0) }, uniquingKeysWith: { first, _ in first })
            for terminal in query.terminals {
                guard let index = tabIndex[terminal.tabID] else { continue }
                guard let tree = bySurface[terminal.surface] else { continue }
                var keys: [ProcessKey] = []
                for process in [tree.host].compactMap({ $0 }) + tree.processes {
                    let key = ProcessKey(host: query.host, pid: process.pid)
                    keys.append(key)
                    samples[key] = ProcessSample(key: key, name: process.name ?? "", cpuNanos: process.cpuNanos,
                                                 memoryBytes: process.memoryBytes, sampledAtNanos: response.sampledAtNanos)
                }
                tabs[index].processes = keys
            }
        }
        return ResourceSampleSet(tabs: tabs, shared: shared, samples: samples)
    }

    // MARK: Resolution (main actor)

    private struct Resolved {
        var tabs: [TabResourceSources] = []
        var daemons: [DaemonQuery] = []
        var rendererClients: [String: [Int32]] = [:]
        /// One tab's sample: the renderer clients of every other page (a renderer they share is not its own).
        var foreignRendererClients: [Int32] = []
        var includesAppShare = false
    }

    private func resolve(_ target: ResourceTarget) -> Resolved {
        var resolved = Resolved()
        let entries: [(TabModel, DaemonService)]
        switch target {
        case .tab(let id):
            guard let (tab, pane) = services.locateTab(id) else { return resolved }
            entries = [(tab, services.daemon(for: pane))]
            resolved.foreignRendererClients = services.cache.browsers.filter { $0.key != tab.id }.flatMap { _, entry -> [Int32] in
                if case .chromiumRendererClients(let clients) = (entry.tab as? any BrowserProcessReporting)?.contentProcesses { clients } else { [] }
            }
        case .workspace(let id):
            guard let (workspace, daemon) = services.machines.workspace(id: id) else { return resolved }
            var seen = Set<String>()
            entries = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                .filter { seen.insert($0.id).inserted }
                .map { ($0, daemon) }
            resolved.includesAppShare = true
        case .everything:
            var seen = Set<String>()
            entries = services.machines.daemons.flatMap { daemon in
                daemon.store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                    .filter { seen.insert($0.id).inserted }
                    .map { ($0, daemon) }
            }
            resolved.includesAppShare = true
        }
        var daemonIndex: [ObjectIdentifier: Int] = [:]
        for (tab, daemon) in entries {
            switch tab.kind {
            case .pty:
                let estimate = services.cache.existingTerminal(tab.id)?.session.surfaceView.memoryEstimateBytes ?? 0
                resolved.tabs.append(TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: .terminal,
                                                        processes: [], estimatedAppBytes: estimate))
                let key = ObjectIdentifier(daemon)
                let index: Int
                if let known = daemonIndex[key] {
                    index = known
                } else {
                    index = resolved.daemons.count
                    daemonIndex[key] = index
                    resolved.daemons.append(DaemonQuery(
                        host: daemon.isLocal ? ProcessKey.localHost : daemon.machineID,
                        connection: daemon.connection,
                        supported: daemon.supports(TerminalResourcesRequest.capability),
                        terminals: []
                    ))
                }
                resolved.daemons[index].terminals.append(TerminalQuery(tabID: tab.id, surface: tab.surface))
            case .browser:
                let page = services.cache.existingBrowser(tab.id)?.tab
                let kind: TabResourceKind = Self.drawsInChromium(tab, page: page) ? .chromium : .webkit
                var sources = TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: kind, processes: [])
                switch Self.contentProcesses(of: page) {
                case .pids(let pids): sources.processes = pids.map { ProcessKey(pid: $0) }
                case .chromiumRendererClients(let clients): resolved.rendererClients[tab.id] = clients
                case .none: break
                }
                resolved.tabs.append(sources)
            case .conversation where tab.agentSession != nil:
                // An agent chat's page (its acpmux agent runs apart); none while it hibernates.
                let pid = agentChatProcess(tab)
                resolved.tabs.append(TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: .webkit,
                                                        processes: pid.map { [ProcessKey(pid: $0)] } ?? [], available: pid != nil))
            case .remoteTerminal, .conversation, .other:
                // A remote reference or a conversation's processes run on its own session.
                resolved.tabs.append(TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: .other,
                                                        processes: [], available: false))
            }
        }
        return resolved
    }

    /// Whether browser tab `tab` draws in Chromium: its page's engine, else the daemon's engine name.
    private static func drawsInChromium(_ tab: TabModel, page: (any BrowserTab)?) -> Bool {
        switch page?.engineKind {
        case .cef: true
        case .webkit: false
        case nil: tab.browserEngine == "cef" || tab.browserEngine == "chromium"
        }
    }

    /// What identifies the processes of a browser tab's page now; `.none` without a page.
    private static func contentProcesses(of page: (any BrowserTab)?) -> BrowserContentProcesses {
        (page as? any BrowserProcessReporting)?.contentProcesses ?? .none
    }

    /// The WebContent process of agent chat `tab`'s page; nil while it hibernates or before it loads.
    private func agentChatProcess(_ tab: TabModel) -> Int32? {
        let view = services.madeAgentTabs.flatMap { $0.views[$0.resolve(tab.id)] }
        return view.flatMap { WebContentProcess.identifier(of: $0.webView) }
    }

    // MARK: `debug.memory` (main actor: one walk of the tabs, IDs and counts only)

    /// The app's memory state for `debug.memory`: the coordinator's report, every tab's content
    /// phase and processes, each workspace's mount state, the terminal surfaces and the spares.
    /// O(tabs + consumers), no disk, no wait; no title, URL or path is read.
    ///
    /// - Parameter history: The pressure changes to include.
    /// - Returns: The snapshot the off-main sampler and the report read.
    func memorySnapshot(history: [MemoryPressureHistory.Change]) -> MemoryDiagnosticsSnapshot {
        let coordinator = services.memoryCoordinator
        let cache = services.cache
        var shown = Set<String>()
        var parked = Set<String>()
        for controller in services.windows.controllers {
            if let content = controller.content { shown.insert(content.workspace.id) }
            parked.formUnion(controller.parked.keys)
        }
        var tabs: [MemoryDiagnosticsSnapshot.Tab] = []
        var workspaces: [MemoryDiagnosticsSnapshot.Workspace] = []
        var seen = Set<String>()
        for workspace in services.machines.daemons.flatMap(\.store.workspaces) {
            let panes = workspace.screens.flatMap(\.panes)
            var row = MemoryDiagnosticsSnapshot.Workspace(
                id: workspace.id, mounted: shown.contains(workspace.id) || parked.contains(workspace.id),
                parked: parked.contains(workspace.id), panes: panes.count)
            for tab in panes.flatMap(\.tabs) where seen.insert(tab.id).inserted {
                let item = memoryTab(tab)
                if cache.existingTerminal(tab.id) != nil {
                    row.terminalSurfaces += 1
                    if cache.ledger.isRendering(tab.id) { row.gpuResidentSurfaces += 1 }
                }
                row.appBytes += item.appBytes ?? 0
                tabs.append(item)
            }
            workspaces.append(row)
        }
        return MemoryDiagnosticsSnapshot(
            report: coordinator.report(budget: services.memoryBudget), kernelLevel: coordinator.kernelLevel,
            override: coordinator.pressureOverride, history: history, tabs: tabs, workspaces: workspaces,
            terminal: memoryTerminal(), spares: memorySpares())
    }

    private func memoryTab(_ tab: TabModel) -> MemoryDiagnosticsSnapshot.Tab {
        let cache = services.cache
        let phase = cache.lifecycle.phase(tab.id)
        let state: MemoryDiagnosticsSnapshot.Tab.State = switch phase {
        case .unmounted: .unmounted
        case .mountedVisible, .mountedHidden: .live
        case .hibernated: .discarded
        case .restoring: .restoring
        case .crashed: .crashed
        }
        var item = MemoryDiagnosticsSnapshot.Tab(id: tab.id, kind: .other, state: state, visible: phase == .mountedVisible)
        switch tab.kind {
        case .pty:
            item.kind = .terminal
            item.appBytes = cache.existingTerminal(tab.id).map { Int(clamping: $0.session.surfaceView.memoryEstimateBytes) }
        case .browser:
            let page = cache.existingBrowser(tab.id)?.tab
            item.kind = .browser
            item.engine = Self.drawsInChromium(tab, page: page) ? .cef : .webkit
            switch Self.contentProcesses(of: page) {
            case .pids(let pids): item.processes = pids.map { .webContent($0) }
            case .chromiumRendererClients(let clients): item.processes = clients.map { .chromiumRendererClient($0) }
            case .none: break
            }
        case .conversation where tab.agentSession != nil:
            item.kind = .agent
            item.engine = .webkit
            item.processes = agentChatProcess(tab).map { [.webContent($0)] } ?? []
        case .remoteTerminal, .conversation, .other:
            break
        }
        return item
    }

    private func memoryTerminal() -> MemoryDiagnosticsSnapshot.Terminal {
        let cache = services.cache
        var rendering = 0
        var hiddenBytes = 0
        for (key, entry) in cache.terminals {
            if cache.ledger.isRendering(key) {
                rendering += 1
            } else {
                hiddenBytes += Int(clamping: entry.session.surfaceView.memoryEstimateBytes)
            }
        }
        return MemoryDiagnosticsSnapshot.Terminal(
            warmCapacity: cache.warmBudget.terminalCapacity, surfaces: cache.terminals.count, gpuResidentCount: rendering,
            hiddenNonvolatileIOSurfaceBytes: hiddenBytes, lastFrames: cache.lastFrames.count)
    }

    private func memorySpares() -> [MemoryDiagnosticsSnapshot.Spare] {
        var spares: [MemoryDiagnosticsSnapshot.Spare] = []
        if let view = services.newTabSpares.spareView {
            spares.append(.init(pool: "new_tab", processKind: .webkitWebContent, pid: WebContentProcess.identifier(of: view.webView)))
        }
        if let host = services.pageHostPool.spareHost {
            spares.append(.init(pool: "page_host", processKind: .webkitWebContent, pid: WebContentProcess.identifier(of: host.webKitView)))
        }
        return spares
    }

    /// The app process, its Chromium helpers and the WebContent processes in `snapshot`, each with
    /// its `phys_footprint` (`proc_pid_rusage`), read off the main actor.
    @concurrent
    nonisolated static func memoryProcesses(_ snapshot: MemoryDiagnosticsSnapshot) async -> MemoryDiagnosticsProcesses {
        func row(_ kind: MemoryDiagnosticsProcesses.Kind, _ pid: Int32) -> MemoryDiagnosticsProcesses.Row {
            .init(kind: kind, pid: pid, physFootprintBytes: ProcessUsage.sample(pid).map { Int(clamping: $0.physFootprint) })
        }
        var rows = [row(.app, getpid())]
        var rendererPIDs: [Int32: Int32] = [:]
        for helper in ChromiumHelperProcess.list() {
            switch helper.kind {
            case .renderer(let client):
                rendererPIDs[client] = helper.pid
                rows.append(row(.chromiumRenderer, helper.pid))
            case .extensionRenderer: rows.append(row(.chromiumRenderer, helper.pid))
            case .gpu: rows.append(row(.chromiumGPU, helper.pid))
            case .network, .utility: rows.append(row(.chromiumUtility, helper.pid))
            case .other: rows.append(row(.other, helper.pid))
            }
        }
        rows += snapshot.webContentPIDs.map { row(.webkitWebContent, $0) }
        return MemoryDiagnosticsProcesses(rows: rows, rendererPIDs: rendererPIDs)
    }

    // MARK: Off the main actor

    @concurrent
    private static func chromiumHelpers() async -> [ChromiumHelperProcess] {
        ChromiumHelperProcess.list()
    }

    @concurrent
    private static func sampleLocal(_ pids: [Int32]) async -> [ProcessKey: ProcessSample] {
        var samples: [ProcessKey: ProcessSample] = [:]
        for pid in pids {
            guard let usage = ProcessUsage.sample(pid) else { continue }
            let key = ProcessKey(pid: pid)
            samples[key] = ProcessSample(key: key, name: usage.name, cpuNanos: usage.cpuNanos,
                                         memoryBytes: usage.physFootprint, sampledAtNanos: usage.uptimeNanos)
        }
        return samples
    }
}
