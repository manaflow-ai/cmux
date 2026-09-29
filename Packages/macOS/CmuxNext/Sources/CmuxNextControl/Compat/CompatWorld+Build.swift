import CmuxNextDaemon
import Foundation

extension CompatWorld {
    /// Joins the daemon tree with the App's frontend state. Workspaces keep
    /// daemon order; panes follow screen order, then layout order; surfaces
    /// follow pane order, then strip order.
    init(tree: DaemonTree, frontend: CompatFrontendSnapshot, refs: CompatRefRegistry) {
        generation = tree.generation?.rawValue
        var windowByWorkspace: [String: [String]] = [:]
        for (index, record) in frontend.windows.enumerated() {
            let uuid = CompatUUID.canonical(record.id) ?? CompatUUID.hashed("window:" + record.id)
            let workspaceUUID = record.workspaceID.map(Self.workspaceUUID(modelID:))
            if let workspaceUUID { windowByWorkspace[workspaceUUID, default: []].append(uuid) }
            windows.append(Window(uuid: uuid, ref: refs.ref(.window, uuid), index: index, modelID: record.id,
                                  workspaceUUID: workspaceUUID, isKey: record.isKey, isVisible: record.isVisible))
            if record.id == frontend.activeWindowID { activeWindowUUID = uuid }
        }
        if activeWindowUUID == nil { activeWindowUUID = windows.first(where: \.isKey)?.uuid ?? windows.first?.uuid }

        for (workspaceIndex, snapshot) in tree.workspaces.enumerated() {
            let modelID = snapshot.key?.rawValue ?? "handle:\(snapshot.id.rawValue)"
            let workspaceUUID = Self.workspaceUUID(modelID: modelID)
            let shownIn = frontend.windows.filter { $0.workspaceID == modelID }
            let frontFocus = shownIn.first(where: { $0.id == frontend.activeWindowID }) ?? shownIn.first
            var selectedTabs: [String: String] = [:]
            for window in shownIn.reversed() { selectedTabs.merge(window.selectedTabs) { _, new in new } }
            if let frontFocus { selectedTabs.merge(frontFocus.selectedTabs) { _, new in new } }

            var paneUUIDs: [String] = []
            var surfaceUUIDs: [String] = []
            var focusedPane: String?
            let activeScreen = snapshot.screens.firstIndex(where: \.active) ?? 0
            for (screenIndex, screen) in snapshot.screens.enumerated() {
                let byID = Dictionary(screen.panes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var order = screen.columns.isEmpty ? screen.layout.paneIDs : screen.columns.flatMap(\.layout.paneIDs)
                order += screen.panes.map(\.id).filter { !order.contains($0) }
                for paneID in order {
                    guard let pane = byID[paneID], !pane.dead else { continue }
                    let paneModelID = pane.resourceID?.rawValue ?? "pane:\(pane.id.rawValue)"
                    let paneUUID = CompatUUID.from(resourceID: paneModelID)
                    let isFrontFocused = frontFocus?.focusedPaneID == paneModelID
                    let isDaemonActive = screenIndex == activeScreen && screen.activePane == pane.id
                    if isFrontFocused || (focusedPane == nil && frontFocus?.focusedPaneID == nil && isDaemonActive) {
                        focusedPane = paneUUID
                    }
                    var paneSurfaces: [String] = []
                    let selectedModel = selectedTabs[paneModelID]
                    var selectedSurface: String?
                    for (tabIndex, tab) in pane.tabs.enumerated() {
                        let tabModelID = Self.tabModelID(tab)
                        let surfaceUUID = CompatUUID.from(resourceID: tabModelID)
                        let isSelected = selectedModel.map { $0 == tabModelID } ?? (tabIndex == pane.activeTab)
                        if isSelected { selectedSurface = surfaceUUID }
                        surfaces[surfaceUUID] = Surface(
                            uuid: surfaceUUID, ref: refs.ref(.surface, surfaceUUID), index: surfaceUUIDs.count,
                            indexInPane: tabIndex, modelID: tabModelID, handle: tab.surface, paneUUID: paneUUID,
                            workspaceUUID: workspaceUUID, tab: tab, selected: isSelected, focused: false)
                        paneSurfaces.append(surfaceUUID)
                        surfaceUUIDs.append(surfaceUUID)
                    }
                    if selectedSurface == nil, let first = paneSurfaces.first {
                        selectedSurface = first
                        surfaces[first]?.selected = true
                    }
                    panes[paneUUID] = Pane(
                        uuid: paneUUID, ref: refs.ref(.pane, paneUUID), index: paneUUIDs.count, modelID: paneModelID,
                        handle: pane.id, workspaceUUID: workspaceUUID, screenIndex: screenIndex, name: pane.name,
                        surfaceUUIDs: paneSurfaces, selectedSurfaceUUID: selectedSurface, focused: false,
                        zoomed: screen.zoomedPane == pane.id)
                    paneUUIDs.append(paneUUID)
                }
            }
            if focusedPane == nil { focusedPane = paneUUIDs.first }
            if let focusedPane {
                panes[focusedPane]?.focused = true
                if let surface = panes[focusedPane]?.selectedSurfaceUUID { surfaces[surface]?.focused = true }
            }
            let custom = snapshot.title.flatMap { $0.isEmpty ? nil : $0 }
            workspaces.append(Workspace(
                uuid: workspaceUUID, ref: refs.ref(.workspace, workspaceUUID), index: workspaceIndex, modelID: modelID,
                key: snapshot.key, handle: snapshot.id, name: snapshot.name, title: snapshot.displayName, customTitle: custom,
                color: snapshot.color, icon: snapshot.icon, group: snapshot.group?.rawValue,
                unreadCount: snapshot.unreadCount ?? 0, paneUUIDs: paneUUIDs, surfaceUUIDs: surfaceUUIDs,
                focusedPaneUUID: focusedPane, windowUUIDs: windowByWorkspace[workspaceUUID] ?? []))
        }
    }

    static func workspaceUUID(modelID: String) -> String {
        CompatUUID.canonical(modelID) ?? CompatUUID.hashed("workspace:" + modelID)
    }

    /// `TabModel.id`: the durable tab resource id when present.
    static func tabModelID(_ tab: TabSnapshot) -> String {
        tab.tabResourceID?.rawValue ?? tab.terminalID.map { "terminal:\($0.rawValue)" } ?? "surface:\(tab.surface.rawValue)"
    }
}
