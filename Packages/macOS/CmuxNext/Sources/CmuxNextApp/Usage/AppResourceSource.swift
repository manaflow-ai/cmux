import CmuxNextBrowser
import CmuxNextDaemon
import CmuxNextResources
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
///   renderers are shared, never a tab's.
/// - WebKit tabs: the web view's WebContent process.
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
            for index in chromiumTabs {
                let clients = resolved.rendererClients[tabs[index].tabID] ?? []
                tabs[index].processes = clients.compactMap { byClient[$0] }.map { ProcessKey(pid: $0) }
            }
            if !resolved.includesAppShare { shared.removeAll() }
        }
        for tab in tabs where tab.kind != .terminal { localPIDs.formUnion(tab.processes.map(\.pid)) }
        localPIDs.formUnion(shared.map(\.key.pid))

        var samples = await Self.sampleLocal(Array(localPIDs))

        // Terminals: one request per daemon.
        for query in resolved.daemons {
            guard query.supported, let connection = query.connection else {
                for terminal in query.terminals {
                    if let index = tabs.firstIndex(where: { $0.tabID == terminal.tabID }) { tabs[index].available = false }
                }
                continue
            }
            let request = TerminalResourcesRequest(surfaces: query.terminals.map(\.surface))
            guard let response = try? await connection.request(request, timeout: .seconds(1)) else {
                for terminal in query.terminals {
                    if let index = tabs.firstIndex(where: { $0.tabID == terminal.tabID }) { tabs[index].available = false }
                }
                continue
            }
            let bySurface = Dictionary(response.terminals.map { ($0.surface, $0) }, uniquingKeysWith: { first, _ in first })
            for terminal in query.terminals {
                guard let index = tabs.firstIndex(where: { $0.tabID == terminal.tabID }) else { continue }
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
        var includesAppShare = false
    }

    private func resolve(_ target: ResourceTarget) -> Resolved {
        var resolved = Resolved()
        let entries: [(TabModel, DaemonService)]
        switch target {
        case .tab(let id):
            guard let (tab, pane) = services.locateTab(id) else { return resolved }
            entries = [(tab, services.daemon(for: pane))]
        case .workspace(let id):
            guard let (workspace, daemon) = services.machines.workspace(id: id) else { return resolved }
            var seen = Set<String>()
            entries = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
                .filter { seen.insert($0.id).inserted }
                .map { ($0, daemon) }
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
                if daemonIndex[key] == nil {
                    daemonIndex[key] = resolved.daemons.count
                    resolved.daemons.append(DaemonQuery(
                        host: daemon.isLocal ? ProcessKey.localHost : daemon.machineID,
                        connection: daemon.connection,
                        supported: daemon.supports(TerminalResourcesRequest.capability),
                        terminals: []
                    ))
                }
                resolved.daemons[daemonIndex[key]!].terminals.append(TerminalQuery(tabID: tab.id, surface: tab.surface))
            case .browser:
                let page = services.cache.existingBrowser(tab.id)?.tab
                let kind: TabResourceKind = switch page?.engineKind {
                case .cef: .chromium
                case .webkit: .webkit
                case nil: tab.browserEngine == "cef" || tab.browserEngine == "chromium" ? .chromium : .webkit
                }
                var sources = TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: kind, processes: [])
                switch (page as? any BrowserProcessReporting)?.contentProcesses ?? .none {
                case .pids(let pids): sources.processes = pids.map { ProcessKey(pid: $0) }
                case .chromiumRendererClients(let clients): resolved.rendererClients[tab.id] = clients
                case .none: break
                }
                resolved.tabs.append(sources)
            case .other:
                resolved.tabs.append(TabResourceSources(tabID: tab.id, title: tab.displayTitle, kind: .other,
                                                        processes: [], available: false))
            }
        }
        return resolved
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
