import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextMemory

/// A terminal surface as `debug.memory` sees it.
struct MemoryTerminalSurface: Equatable {
    /// The surface's app-side estimate (drawables and cell buffers); nil before it attaches or after it is freed.
    var estimateBytes: Int?
    /// Whether the surface ledger has it drawing.
    var rendering: Bool
}

/// A browser tab's content as `debug.memory` sees it.
struct MemoryBrowserContent: Equatable {
    /// Whether it draws in Chromium (else WebKit).
    var chromium: Bool
    var processes: BrowserContentProcesses
}

/// What `debug.memory` reads from the app on the main actor: the seam between the app's services
/// (``AppMemoryModel``) and ``memorySnapshot(history:)``, so a test builds a snapshot from a fake app.
/// Each read is O(1) or one pass over its list; none reads a title, URL or path, or waits.
@MainActor
protocol MemorySnapshotModel {
    /// The coordinator's report: level, mode, budget and consumers.
    var memoryReport: MemoryReport { get }
    var kernelPressure: MemoryPressureLevel { get }
    var pressureOverride: MemoryPressureLevel? { get }
    /// Every workspace of every daemon, in store order.
    var memoryWorkspaces: [WorkspaceModel] { get }
    /// The workspaces windows show now (multi-view companions included) and the ones they keep
    /// parked off screen; no ID is in both.
    func workspaceMounts() -> (onScreen: Set<String>, parked: Set<String>)
    func contentPhase(_ tabID: String) -> ContentLifecycle<String>.Phase
    /// The terminal surface of `tabID`; nil when the cache has none.
    func terminalSurface(_ tabID: String) -> MemoryTerminalSurface?
    func browserContent(_ tab: TabModel) -> MemoryBrowserContent
    /// The WebContent process of an agent chat's page; nil while it hibernates or before it loads.
    func agentChatProcess(_ tab: TabModel) -> Int32?
    /// The terminal cache's counts.
    var memoryTerminal: MemoryDiagnosticsSnapshot.Terminal { get }
    var memorySpares: [MemoryDiagnosticsSnapshot.Spare] { get }
    /// The renderer client ids of every Chromium page the app holds; nil without Chromium
    /// (``MemoryDiagnosticsSnapshot/rendererClientsInUse``).
    var memoryRendererClientsInUse: Set<Int32>? { get }
}

extension MemorySnapshotModel {
    /// The app's memory state for `debug.memory`, in one main-actor walk of the tabs:
    /// O(tabs + consumers), no disk, no wait. Each tab is in its first workspace only.
    ///
    /// - Parameter history: The pressure history to include.
    /// - Returns: The snapshot the off-main sampler and the report read.
    func memorySnapshot(history: MemoryPressureHistory.Snapshot) -> MemoryDiagnosticsSnapshot {
        let mounts = workspaceMounts()
        var tabs: [MemoryDiagnosticsSnapshot.Tab] = []
        var workspaces: [MemoryDiagnosticsSnapshot.Workspace] = []
        var seen = Set<String>()
        for workspace in memoryWorkspaces {
            let panes = workspace.screens.flatMap(\.panes)
            let state: MemoryDiagnosticsSnapshot.Workspace.State =
                mounts.onScreen.contains(workspace.id) ? .mounted : mounts.parked.contains(workspace.id) ? .parked : .unmounted
            var row = MemoryDiagnosticsSnapshot.Workspace(id: workspace.id, state: state, panes: panes.count)
            for tab in panes.flatMap(\.tabs) where seen.insert(tab.id).inserted {
                let surface = tab.kind == .pty ? terminalSurface(tab.id) : nil
                if let surface {
                    row.terminalSurfaces += 1
                    if surface.rendering { row.renderingSurfaces += 1 }
                }
                tabs.append(memoryTab(tab, surface: surface))
                row.tabKeys.append(tab.id)
            }
            workspaces.append(row)
        }
        return MemoryDiagnosticsSnapshot(
            report: memoryReport, kernelLevel: kernelPressure, override: pressureOverride, history: history, tabs: tabs,
            workspaces: workspaces, terminal: memoryTerminal, spares: memorySpares, rendererClientsInUse: memoryRendererClientsInUse)
    }

    private func memoryTab(_ tab: TabModel, surface: MemoryTerminalSurface?) -> MemoryDiagnosticsSnapshot.Tab {
        let phase = contentPhase(tab.id)
        var item = MemoryDiagnosticsSnapshot.Tab(key: tab.id, kind: .other, state: Self.state(phase), visible: phase == .mountedVisible)
        switch tab.kind {
        case .pty:
            item.kind = .terminal
            item.appBytes = surface?.estimateBytes
        case .browser:
            let content = browserContent(tab)
            item.kind = .browser
            item.engine = content.chromium ? .cef : .webkit
            switch content.processes {
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

    private static func state(_ phase: ContentLifecycle<String>.Phase) -> MemoryDiagnosticsSnapshot.Tab.State {
        switch phase {
        case .unmounted: .unmounted
        case .mountedVisible, .mountedHidden: .live
        case .hibernated: .discarded
        case .restoring: .restoring
        case .crashed: .crashed
        }
    }
}
