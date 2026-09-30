import CmuxNextDaemon
import Foundation

extension CompatWorld {
    /// Builds the CLI view of a `ControlTopology`: old-app UUIDs, refs, and
    /// indexes. Workspaces keep topology order, panes screen then pane
    /// order, surfaces pane then strip order. Focus and selection come from
    /// the topology's windows and panes (app-local state), falling back to
    /// the first pane and tab.
    init(topology: ControlTopology, refs: CompatRefRegistry) {
        let activeWindowID = topology.focus.windowID ?? topology.windows.first(where: \.isKey)?.id ?? topology.windows.first?.id
        var windowsByWorkspace: [String: [String]] = [:]
        for (index, info) in topology.windows.enumerated() {
            let uuid = CompatUUID.canonical(info.id) ?? CompatUUID.hashed("window:" + info.id)
            let workspaceUUID = info.workspaceID.map(Self.workspaceUUID(modelID:))
            if let workspaceUUID { windowsByWorkspace[workspaceUUID, default: []].append(uuid) }
            windows.append(Window(uuid: uuid, ref: refs.ref(.window, uuid), index: index, modelID: info.id,
                                  workspaceUUID: workspaceUUID, workspaceUUIDs: info.workspaceIDs.map(Self.workspaceUUID(modelID:)),
                                  isKey: info.isKey, isVisible: info.isVisible))
            if info.id == activeWindowID { activeWindowUUID = uuid }
        }
        for (workspaceIndex, info) in topology.workspaces.enumerated() {
            let workspaceUUID = Self.workspaceUUID(modelID: info.id)
            let shownIn = topology.windows.filter { $0.workspaceID == info.id }
            let front = shownIn.first { $0.id == activeWindowID } ?? shownIn.first
            let focusedModel = front?.focusedPaneID ?? (topology.focus.workspaceID == info.id ? topology.focus.paneID : nil)
            var paneUUIDs: [String] = []
            var surfaceUUIDs: [String] = []
            var focusedPane: String?
            for (screenIndex, screen) in info.screens.enumerated() {
                for pane in screen.panes {
                    let paneUUID = CompatUUID.from(resourceID: pane.id)
                    if pane.id == focusedModel { focusedPane = paneUUID }
                    var paneSurfaces: [String] = []
                    var selectedSurface: String?
                    for (tabIndex, tab) in pane.tabs.enumerated() {
                        let surfaceUUID = CompatUUID.from(resourceID: tab.id)
                        let selected = pane.selectedTabID.map { $0 == tab.id } ?? (tabIndex == 0)
                        if selected { selectedSurface = surfaceUUID }
                        surfaces[surfaceUUID] = Surface(
                            uuid: surfaceUUID, ref: refs.ref(.surface, surfaceUUID), index: surfaceUUIDs.count,
                            indexInPane: tabIndex, modelID: tab.id, handle: SurfaceID(rawValue: UInt64(tab.surface) ?? 0),
                            paneUUID: paneUUID, workspaceUUID: workspaceUUID, tab: Self.facts(tab), selected: selected, focused: false)
                        paneSurfaces.append(surfaceUUID)
                        surfaceUUIDs.append(surfaceUUID)
                    }
                    if selectedSurface == nil, let first = paneSurfaces.first {
                        selectedSurface = first
                        surfaces[first]?.selected = true
                    }
                    panes[paneUUID] = Pane(
                        uuid: paneUUID, ref: refs.ref(.pane, paneUUID), index: paneUUIDs.count, modelID: pane.id,
                        handle: PaneID(rawValue: UInt64(pane.handle) ?? 0), workspaceUUID: workspaceUUID, screenIndex: screenIndex,
                        name: pane.name, surfaceUUIDs: paneSurfaces, selectedSurfaceUUID: selectedSurface, focused: false,
                        zoomed: screen.zoomedPaneID == pane.id)
                    paneUUIDs.append(paneUUID)
                }
            }
            if focusedPane == nil { focusedPane = paneUUIDs.first }
            if let focusedPane {
                panes[focusedPane]?.focused = true
                if let surface = panes[focusedPane]?.selectedSurfaceUUID { surfaces[surface]?.focused = true }
            }
            let custom = info.title.flatMap { $0.isEmpty ? nil : $0 }
            workspaces.append(Workspace(
                uuid: workspaceUUID, ref: refs.ref(.workspace, workspaceUUID), index: workspaceIndex, modelID: info.id,
                key: CompatUUID.canonical(info.id) != nil ? WorkspaceKey(rawValue: info.id) : nil,
                handle: WorkspaceHandle(rawValue: UInt64(info.handle) ?? 0), name: info.name, title: custom ?? info.name,
                customTitle: custom, color: info.color, icon: info.icon, group: info.groupID, unreadCount: info.unreadCount,
                paneUUIDs: paneUUIDs, surfaceUUIDs: surfaceUUIDs, focusedPaneUUID: focusedPane,
                windowUUIDs: windowsByWorkspace[workspaceUUID] ?? []))
        }
    }

    static func facts(_ tab: ControlTabInfo) -> Tab {
        Tab(kind: tab.kind, title: tab.title, terminalID: tab.terminalID, cwd: tab.cwd, url: tab.url, gitBranch: tab.gitBranch,
            pinned: tab.isPinned, dead: tab.isDead, unread: tab.hasUnread)
    }

    static func workspaceUUID(modelID: String) -> String {
        CompatUUID.canonical(modelID) ?? CompatUUID.hashed("workspace:" + modelID)
    }
}
