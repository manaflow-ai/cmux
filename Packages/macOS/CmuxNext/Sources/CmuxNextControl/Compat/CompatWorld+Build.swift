import CmuxNextDaemon
import Foundation

extension CompatWorld {
    /// Builds the CLI view of a `ControlTopology`: old-app UUIDs, refs, and
    /// indexes. Workspaces keep topology order, panes screen then pane
    /// order, surfaces pane then strip order. Focus and selection come from
    /// the topology's windows and panes (app-local state), falling back to
    /// the first pane and tab.
    init(topology: ControlTopology, refs: CompatRefRegistry) {
        sessions = topology.sessions.map(Self.session).sorted { $0.isHome && !$1.isHome }
        let homeID = topology.homeSession?.id
        // Shown windows first, so indexes 0... name what the user sees and a
        // window kept off screen never becomes the default target.
        let ordered = topology.windows.filter { !$0.isHidden } + topology.windows.filter(\.isHidden)
        let shown = ordered.filter { !$0.isHidden }
        let activeWindowID = topology.focus.windowID ?? shown.first(where: \.isKey)?.id ?? shown.first?.id
        var windowsByWorkspace: [String: [String]] = [:]
        for (index, info) in ordered.enumerated() {
            let uuid = CompatUUID.canonical(info.id) ?? CompatUUID.hashed("window:" + info.id)
            let workspaceUUID = info.workspaceID.map(Self.workspaceUUID(modelID:))
            if let workspaceUUID { windowsByWorkspace[workspaceUUID, default: []].append(uuid) }
            var window = Window(uuid: uuid, ref: refs.ref(.window, uuid), index: index, modelID: info.id,
                                workspaceUUID: workspaceUUID, workspaceUUIDs: info.workspaceIDs.map(Self.workspaceUUID(modelID:)),
                                isKey: info.isKey, isVisible: info.isVisible)
            window.isHidden = info.isHidden
            window.visibleWorkspaceUUIDs = (info.visibleWorkspaceIDs ?? info.workspaceIDs).map(Self.workspaceUUID(modelID:))
            windows.append(window)
            if info.id == activeWindowID { activeWindowUUID = uuid }
        }
        var indexBySession: [String: Int] = [:]
        // Home workspaces first so home indexes match the single-session app.
        let orderedWorkspaces = topology.workspaces.filter { $0.sessionID == nil || $0.sessionID == homeID }
            + topology.workspaces.filter { $0.sessionID != nil && $0.sessionID != homeID }
        for info in orderedWorkspaces {
            let sessionID = info.sessionID == homeID ? nil : info.sessionID
            let session = sessionID.flatMap { id in sessions.first { $0.id == id } }
            let record = session ?? sessions.first(where: \.isHome)
            let workspaceIndex = indexBySession[sessionID ?? "", default: 0]
            indexBySession[sessionID ?? ""] = workspaceIndex + 1
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
                            uuid: surfaceUUID, ref: refs.ref(.surface, surfaceUUID, session: session), index: surfaceUUIDs.count,
                            indexInPane: tabIndex, modelID: tab.id, handle: SurfaceID(rawValue: UInt64(tab.surface) ?? 0),
                            paneUUID: paneUUID, workspaceUUID: workspaceUUID, tab: Self.facts(tab), selected: selected, focused: false,
                            sessionID: sessionID, session: record)
                        paneSurfaces.append(surfaceUUID)
                        surfaceUUIDs.append(surfaceUUID)
                    }
                    if selectedSurface == nil, let first = paneSurfaces.first {
                        selectedSurface = first
                        surfaces[first]?.selected = true
                    }
                    panes[paneUUID] = Pane(
                        uuid: paneUUID, ref: refs.ref(.pane, paneUUID, session: session), index: paneUUIDs.count, modelID: pane.id,
                        handle: PaneID(rawValue: UInt64(pane.handle) ?? 0), workspaceUUID: workspaceUUID, screenIndex: screenIndex,
                        name: pane.name, surfaceUUIDs: paneSurfaces, selectedSurfaceUUID: selectedSurface, focused: false,
                        zoomed: screen.zoomedPaneID == pane.id, sessionID: sessionID, session: record)
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
                uuid: workspaceUUID, ref: refs.ref(.workspace, workspaceUUID, session: session), index: workspaceIndex, modelID: info.id,
                key: CompatUUID.canonical(info.id) != nil ? WorkspaceKey(rawValue: info.id) : nil,
                handle: WorkspaceHandle(rawValue: UInt64(info.handle) ?? 0), name: info.name, title: custom ?? info.name,
                customTitle: custom, color: info.color, icon: info.icon, group: info.groupID, unreadCount: info.unreadCount,
                paneUUIDs: paneUUIDs, surfaceUUIDs: surfaceUUIDs, focusedPaneUUID: focusedPane,
                windowUUIDs: windowsByWorkspace[workspaceUUID] ?? [], sessionID: sessionID, session: record))
        }
    }

    static func session(_ info: ControlSessionInfo) -> Session {
        Session(id: info.id, qualifier: info.qualifier, machineID: info.machineID, machineName: info.machineName,
                sessionName: info.sessionName, isHome: info.isHome, state: info.state, transport: info.transport)
    }

    static func facts(_ tab: ControlTabInfo) -> Tab {
        Tab(kind: tab.kind, title: tab.title, terminalID: tab.terminalID, cwd: tab.cwd, url: tab.url, gitBranch: tab.gitBranch,
            pinned: tab.isPinned, dead: tab.isDead, unread: tab.hasUnread)
    }

    static func workspaceUUID(modelID: String) -> String {
        CompatUUID.canonical(modelID) ?? CompatUUID.hashed("workspace:" + modelID)
    }
}
