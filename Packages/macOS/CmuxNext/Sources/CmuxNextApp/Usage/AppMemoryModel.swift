import CmuxNextAgentPane
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextMemory
import CmuxNextPages
import CmuxNextResources
import CmuxNextTerminal
import CmuxNextWakeups
import Darwin

/// The app's ``MemorySnapshotModel``: `debug.memory`'s reads of the services, IDs, kinds and counts
/// only. ``processes(_:)`` reads the footprints off the main actor.
@MainActor
struct AppMemoryModel: MemorySnapshotModel {
    let services: AppServices
    /// The budgets the report shows (``DebugMemoryControl/budget``).
    let budget: SubsystemBudget

    var memoryReport: MemoryReport { services.memoryCoordinator.report(budget: budget) }
    var kernelPressure: MemoryPressureLevel { services.memoryCoordinator.kernelLevel }
    var pressureOverride: MemoryPressureLevel? { services.memoryCoordinator.pressureOverride }
    var memoryWorkspaces: [WorkspaceModel] { services.machines.daemons.flatMap(\.store.workspaces) }

    func workspaceMounts() -> (onScreen: Set<String>, parked: Set<String>) {
        var onScreen = Set<String>()
        var parked = Set<String>()
        for controller in services.windows.controllers {
            onScreen.formUnion(controller.onScreenContents.map(\.workspace.id))
            parked.formUnion(controller.parked.keys)
        }
        return (onScreen, parked.subtracting(onScreen))
    }

    func contentPhase(_ tabID: String) -> ContentLifecycle<String>.Phase {
        services.cache.lifecycle.phase(tabID)
    }

    func terminalSurface(_ tabID: String) -> MemoryTerminalSurface? {
        guard let entry = services.cache.existingTerminal(tabID) else { return nil }
        return MemoryTerminalSurface(estimateBytes: entry.session.memoryEstimateBytes.map { Int(clamping: $0) },
                                     rendering: services.cache.ledger.isRendering(tabID))
    }

    func browserContent(_ tab: TabModel) -> MemoryBrowserContent {
        let page = services.cache.existingBrowser(tab.id)?.tab
        return MemoryBrowserContent(chromium: AppResourceSource.drawsInChromium(tab, page: page),
                                    processes: AppResourceSource.contentProcesses(of: page))
    }

    func agentChatProcess(_ tab: TabModel) -> Int32? {
        AppResourceSource.agentChatProcess(tab, in: services)
    }

    var memoryTerminal: MemoryDiagnosticsSnapshot.Terminal {
        let cache = services.cache
        let rendering = cache.terminals.keys.filter { cache.ledger.isRendering($0) }.count
        // Hidden: away from the viewport, outside the keep-alive band (whose surfaces stay resident), or
        // shown in an off-screen window (resident until the window stays off screen 30 s).
        let hidden = cache.terminals.filter { cache.ledger.isAway($0.key) || $0.value.session.isInOffScreenWindow }.values
        let hiddenBytes = hidden.reduce(0) { $0 + Int(clamping: $1.session.pausedNonvolatileIOSurfaceBytes) }
        return MemoryDiagnosticsSnapshot.Terminal(
            warmCapacity: cache.warmBudget.terminalCapacity, surfaces: cache.terminals.count, rendering: rendering,
            hiddenNonvolatileIOSurfaceBytes: hiddenBytes, lastFrames: cache.lastFrames.count)
    }

    var memorySpares: [MemoryDiagnosticsSnapshot.Spare] {
        var spares: [MemoryDiagnosticsSnapshot.Spare] = []
        if let view = services.newTabSpares.spareView {
            spares.append(.init(pool: "new_tab", processKind: .webkitWebContent, pid: Self.webContentProcess(of: view.page)))
        }
        if let page = services.pagePreloads.heldPage, !page.showsChromium {
            spares.append(.init(pool: "page_preload", processKind: .webkitWebContent, pid: Self.webContentProcess(of: page)))
        }
        // Chromium's spare windows; their placeholder's renderer, when it has one, gives the pid.
        // A read never builds the engine: none built, no spare window.
        for window in services.cache.chromium.built?.spareWindowRenderers ?? [] {
            spares.append(.init(pool: window.pool, processKind: .chromiumRenderer, pid: nil, rendererClients: window.rendererClients))
        }
        return spares
    }

    /// The WebContent processes of the live WebKit pages, agent chats and spares, each once: what
    /// ``MemoryFootprintEmitter`` samples. It reads the live web views only (no workspace, tab or
    /// memory report walk), so it costs O(live web views).
    static func liveWebContentPIDs(_ services: AppServices) -> [Int32] {
        var seen = Set<Int32>()
        var pids: [Int32] = []
        func add(_ pid: Int32?) {
            if let pid, seen.insert(pid).inserted { pids.append(pid) }
        }
        for entry in services.cache.browsers.values {
            if case .pids(let list) = AppResourceSource.contentProcesses(of: entry.tab) { list.forEach(add) }
        }
        if let agentTabs = services.madeAgentTabs {
            for view in agentTabs.views.values { add(webContentProcess(of: view.page)) }
        }
        if let view = services.newTabSpares.spareView { add(webContentProcess(of: view.page)) }
        if let page = services.pagePreloads.heldPage { add(webContentProcess(of: page)) }
        return pids
    }

    /// The WebContent process of `page` while WebKit shows it; nil while Chromium does (its renderer
    /// is a Chromium helper, counted with the helpers).
    static func webContentProcess(of page: PageWebView) -> Int32? {
        page.webKitEngine.flatMap { WebContentProcess.identifier(of: $0) }
    }

    /// The renderer client ids that host a frame of any Chromium browser (``CEFEngine/rendererClientsWithFrames``),
    /// nil while no engine is built: a read never builds it.
    static func rendererClientsWithFrames(_ services: AppServices?) -> Set<Int32>? {
        services?.cache.chromium.built?.rendererClientsWithFrames
    }

    /// The app process, the Chromium helpers of `helperParent` and the WebContent processes in `snapshot`, each
    /// with its `phys_footprint` (`proc_pid_rusage`), read off the main actor; then, on the main actor, the
    /// renderer clients that host a frame (`rendererClientsWithFrames`). That read comes after the helpers
    /// were listed, so a renderer that started and committed its page before it is not taken for one that
    /// hosts no frame.
    @concurrent
    nonisolated static func processes(_ snapshot: MemoryDiagnosticsSnapshot, helperParent: pid_t?,
                                      rendererClientsWithFrames: @escaping @MainActor @Sendable () -> Set<Int32>?) async
        -> MemoryDiagnosticsProcesses {
        var sampled = await processes(webContentPIDs: snapshot.webContentPIDs, helperParent: helperParent)
        sampled.rendererClientsWithFrames = await rendererClientsWithFrames()
        return sampled
    }

    /// The app process, the Chromium helpers of `helperParent` (``ChromiumHelperParent/pid``: the app in process, the
    /// Chromium Host in host mode) and the WebContent processes `webContentPIDs`, each with its `phys_footprint`
    /// (`proc_pid_rusage`), read off the main actor.
    @concurrent
    nonisolated static func processes(webContentPIDs: [Int32], helperParent: pid_t?) async -> MemoryDiagnosticsProcesses {
        func row(_ kind: MemoryDiagnosticsProcesses.Kind, _ pid: Int32) -> MemoryDiagnosticsProcesses.Row {
            .init(kind: kind, pid: pid, physFootprintBytes: ProcessUsage.sample(pid).map { Int(clamping: $0.physFootprint) })
        }
        var rows = [row(.app, getpid())]
        var rendererPIDs: [Int32: Int32] = [:]
        for helper in ChromiumHelperProcess.list(parent: helperParent) {
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
        rows += webContentPIDs.map { row(.webkitWebContent, $0) }
        return MemoryDiagnosticsProcesses(rows: rows, rendererPIDs: rendererPIDs)
    }
}
