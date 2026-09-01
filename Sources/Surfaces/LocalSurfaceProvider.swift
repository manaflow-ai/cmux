import AppKit
import Bonsplit
import Foundation

/// This Mac as a surface provider.
///
/// Every live terminal and browser pane on this Mac is a resource whose single projection
/// is the pane itself: Ghostty owns the PTY and WebKit owns the page, so a local resource
/// cannot be shown twice — "projecting" it somewhere else moves the pane. Resources are
/// keyed by the panel UUID and stay in sync through the workspace hooks in
/// `Workspace+SurfaceCatalog.swift` (no polling).
@MainActor
final class LocalSurfaceProvider: SurfaceProvider {
    static let shared = LocalSurfaceProvider(
        catalog: .shared,
        workspaces: { AppDelegate.shared?.surfaceCatalogWorkspaces() ?? [] }
    )

    let machine: SurfaceMachineID = .local
    private let catalog: SurfaceCatalog
    private let workspaces: () -> [Workspace]

    /// - Parameters:
    ///   - catalog: the catalog this provider feeds (tests pass a fresh one).
    ///   - workspaces: every workspace whose panes count as local resources.
    init(catalog: SurfaceCatalog, workspaces: @escaping () -> [Workspace]) {
        self.catalog = catalog
        self.workspaces = workspaces
    }

    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: .local,
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            status: "running",
            image: nil,
            hasDesktop: false,
            memoryMb: Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024)),
            diskMb: nil,
            linkState: .notApplicable,
            linkError: nil,
            cpuPercent: nil,
            memoryUsedMb: nil,
            diskUsedMb: nil
        )
    }

    // MARK: Resources

    static func resourceID(forTerminalPanel panelID: UUID) -> SurfaceResourceID {
        SurfaceResourceID(machine: .local, kind: .terminal, key: panelID.uuidString)
    }

    static func resourceID(forBrowserPanel panelID: UUID) -> SurfaceResourceID {
        SurfaceResourceID(machine: .local, kind: .browser, key: panelID.uuidString)
    }

    /// The resource a pane represents, or nil for pane kinds that are not surfaces
    /// (markdown, file preview, tools, loading placeholders, …).
    func resource(for panel: any Panel, in workspace: Workspace) -> SurfaceResource? {
        let title = workspace.panelTitles[panel.id].flatMap { $0.isEmpty ? nil : $0 } ?? panel.displayTitle
        if panel is TerminalPanel {
            return SurfaceResource(
                id: Self.resourceID(forTerminalPanel: panel.id),
                title: title,
                detail: workspace.panelDirectories[panel.id],
                lifecycle: .running,
                agent: nil,
                remoteWorkspace: nil,
                port: nil,
                url: nil
            )
        }
        if let browser = panel as? BrowserPanel {
            return SurfaceResource(
                id: Self.resourceID(forBrowserPanel: panel.id),
                title: title,
                detail: browser.currentURL?.absoluteString,
                lifecycle: .running,
                agent: nil,
                remoteWorkspace: nil,
                port: nil,
                url: browser.currentURL?.absoluteString
            )
        }
        return nil
    }

    // MARK: Workspace hooks

    /// A pane joined a workspace: a brand-new pane becomes a resource with one projection;
    /// a pane arriving from another workspace (tab transfer) keeps its resource and its
    /// projection moves. A pane already projecting a remote resource is left alone.
    func panelDidAppear(_ panel: any Panel, in workspace: Workspace) {
        guard let resource = resource(for: panel, in: workspace) else { return }
        if let existing = catalog.projection(forPanel: panel.id) {
            if existing.resource.machine.isLocal {
                catalog.upsert(resource)
            }
            catalog.moveProjections(panelID: panel.id, to: workspace.id)
            return
        }
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panel.id))
    }

    /// Title or working directory changed for a pane that projects a local resource.
    /// A busy shell retitles many times per second; changes are coalesced to one pass
    /// per main-runloop turn and only pushed to the catalog when the resource actually
    /// differs from what it already holds.
    func panelDidChange(panelID: UUID, in workspace: Workspace) {
        pendingChanges[panelID] = workspace
        guard !changeFlushScheduled else { return }
        changeFlushScheduled = true
        Task { @MainActor [weak self] in
            self?.flushPendingChanges()
        }
    }

    private var pendingChanges: [UUID: Workspace] = [:]
    private var changeFlushScheduled = false

    private func flushPendingChanges() {
        changeFlushScheduled = false
        let changes = pendingChanges
        pendingChanges.removeAll()
        for (panelID, workspace) in changes {
            guard let projection = catalog.projection(forPanel: panelID), projection.resource.machine.isLocal,
                  let panel = workspace.panels[panelID],
                  let resource = resource(for: panel, in: workspace) else { continue }
            if catalog.resources[resource.id] != resource {
                catalog.upsert(resource)
            }
        }
    }

    /// A pane left a workspace for good (closed, torn down). Transfers never reach this.
    func panelWillDisappear(panelID: UUID) {
        catalog.endProjections(panelID: panelID)
    }

    func projectionDidEnd(_ projection: SurfaceProjection) {
        guard projection.resource.machine.isLocal else { return }
        catalog.remove(projection.resource)
    }

    /// Local materialization moves an existing pane instead of creating one. A late result
    /// therefore must not close that pane through the shared discard implementation.
    @discardableResult
    func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
        true
    }

    // MARK: SurfaceProvider

    func refresh() async {
        var list: [SurfaceResource] = []
        var projections: [SurfaceProjection] = []
        for workspace in workspaces() {
            for (panelID, panel) in workspace.panels {
                if let remote = catalog.projection(forPanel: panelID), !remote.resource.machine.isLocal { continue }
                guard let resource = resource(for: panel, in: workspace) else { continue }
                list.append(resource)
                projections.append(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID))
            }
        }
        catalog.replaceResources(list, on: .local, info: info)
        for projection in projections where catalog.projection(forPanel: projection.panelID) == nil {
            catalog.record(projection)
        }
    }

    /// Where a move lands, in Bonsplit terms.
    struct MoveTarget: Equatable {
        var pane: PaneID?
        var index: Int?
        var split: (orientation: SplitOrientation, insertFirst: Bool)?

        static func == (lhs: MoveTarget, rhs: MoveTarget) -> Bool {
            lhs.pane == rhs.pane && lhs.index == rhs.index
                && lhs.split?.orientation == rhs.split?.orientation && lhs.split?.insertFirst == rhs.split?.insertFirst
        }
    }

    /// Maps a catalog destination onto the pane/index/split triple `moveBonsplitTab` takes.
    /// `.left`/`.up` insert before the target pane, `.right`/`.down` after — the same
    /// convention `Workspace.handleSessionDrop` uses for dropped Vault sessions.
    static func moveTarget(for destination: SurfaceDestination, focusedPane: PaneID?) -> MoveTarget {
        switch destination {
        case .workspace(_, let placement):
            switch placement {
            case .split: return MoveTarget(pane: focusedPane, index: nil, split: (.horizontal, false))
            case .tab: return MoveTarget(pane: focusedPane, index: nil, split: nil)
            }
        case .split(_, let paneID, let direction):
            let pane = UUID(uuidString: paneID).map(PaneID.init(id:))
            switch direction {
            case .left: return MoveTarget(pane: pane, index: nil, split: (.horizontal, true))
            case .right: return MoveTarget(pane: pane, index: nil, split: (.horizontal, false))
            case .up: return MoveTarget(pane: pane, index: nil, split: (.vertical, true))
            case .down: return MoveTarget(pane: pane, index: nil, split: (.vertical, false))
            }
        case .tab(_, let paneID, let index):
            return MoveTarget(pane: UUID(uuidString: paneID).map(PaneID.init(id:)), index: index, split: nil)
        }
    }

    /// A local resource is its pane: materializing it elsewhere moves the pane there.
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        guard let panelID = UUID(uuidString: resource.id.key),
              let current = catalog.projection(forPanel: panelID),
              let source = workspaces().first(where: { $0.id == current.workspaceID }),
              let tabID = source.surfaceIdFromPanelId(panelID) else {
            throw SurfaceCatalogError.unknownResource(resource.id)
        }
        guard let target = workspaces().first(where: { $0.id == destination.workspaceID }) else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        let moveTarget = Self.moveTarget(
            for: destination,
            focusedPane: target.bonsplitController.focusedPaneId ?? target.bonsplitController.allPaneIds.first
        )
        guard let app = AppDelegate.shared else { throw SurfaceCatalogError.unsupported("no app delegate") }
        guard app.moveBonsplitTab(
            tabId: tabID.uuid,
            toWorkspace: target.id,
            targetPane: moveTarget.pane,
            targetIndex: moveTarget.index,
            splitTarget: moveTarget.split,
            focus: focus,
            focusWindow: focus
        ) else {
            throw SurfaceCatalogError.unsupported("move \(resource.id) to \(destination)")
        }
        return SurfaceProjection(resource: resource.id, workspaceID: target.id, panelID: panelID)
    }

    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        let all = workspaces()
        guard let workspace = all.first(where: { $0.owningTabManager?.selectedTabId == $0.id }) ?? all.first else {
            throw SurfaceCatalogError.destinationNotFound("a workspace")
        }
        let initialCommand = command.map { $0.map(Self.shellQuote).joined(separator: " ") }
        let made = try SurfacePaneFactory.makeTerminalPane(
            initialCommand: initialCommand,
            workingDirectory: cwd,
            at: .workspace(id: workspace.id, placement: .split),
            focus: true
        )
        let id = Self.resourceID(forTerminalPanel: made.panelID)
        if var resource = catalog.resources[id] {
            if let name, !name.isEmpty { resource.title = name; catalog.upsert(resource) }
            return resource
        }
        let resource = SurfaceResource(id: id, title: name ?? "shell", detail: cwd, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: nil, url: nil)
        catalog.upsert(resource)
        catalog.record(SurfaceProjection(resource: id, workspaceID: made.workspaceID, panelID: made.panelID))
        return resource
    }

    static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.range(of: "^[A-Za-z0-9_./:=@%+-]+$", options: .regularExpression) != nil { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
