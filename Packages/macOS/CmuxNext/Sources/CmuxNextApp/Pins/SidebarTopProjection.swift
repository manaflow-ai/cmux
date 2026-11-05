import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextSidebar

/// Workspaces in the top region (PINNED-ITEMS-END-TO-END P1, P2): how a
/// workspace tile or top row draws, and the workspace list's projection.
/// A workspace the top region shows leaves the list (projection only: its
/// place in the personal order stays, so unpinning returns the row to its
/// old place). The legacy Pinned list section (`workspace-pin-v1`) draws
/// only while pins are not layout tiles.
enum SidebarTopProjection: Equatable {
    /// Legacy: pinned workspaces move into the Pinned list section.
    case legacy
    /// Layout tiles: these sidebar workspace ids leave the list.
    case layout(hidden: Set<String>)

    /// The projection for a window showing `room`.
    @MainActor static func make(_ layout: SidebarLayoutService, machines: MachineRegistry, room: String?) -> SidebarTopProjection {
        guard layout.unavailableReason == nil else { return .legacy }
        return .layout(hidden: WorkspaceLayoutRefs(machines: machines).topWorkspaceIDs(in: layout.document, room: room))
    }

    /// `filtered` (the window's rows) under this projection.
    @MainActor func apply(to filtered: [SidebarRowSection], machines: MachineRegistry) -> [SidebarRowSection] {
        switch self {
        case .legacy:
            let pinned = Set(machines.daemons.flatMap { $0.store.workspaces.filter(\.pinned).map(\.id) })
            return SidebarRowSection.pinnedFirst(filtered, pinned: pinned)
        case .layout(let hidden):
            return SidebarRowSection.hiding(filtered, workspaces: hidden)
        }
    }
}

/// How workspace tiles and top rows draw.
@MainActor
struct SidebarWorkspaceItems {
    /// How each open workspace a layout item names draws; a ref with no
    /// entry is closed or another device's (drawn dimmed by the fallback).
    /// `favicon` gives a page tab's favicon (`AppServices.sidebarPageFavicon`), so a site's item shows it once it loads.
    static func workspaceInfos(_ layout: SidebarLayoutDocument, refs: WorkspaceLayoutRefs,
                               favicon: (WorkspaceModel, TabModel) -> SidebarFavicon? = { _, _ in nil }) -> [LayoutItemRef: SidebarItemInfo] {
        var infos: [LayoutItemRef: SidebarItemInfo] = [:]
        for item in layout.sections.lazy.flatMap(\.items) where item.ref.kind == LayoutItemRef.workspaceKind && infos[item.ref] == nil {
            if let (workspace, daemon) = refs.workspace(for: item.ref) {
                infos[item.ref] = workspaceInfo(workspace, machine: MachineID(daemon.machineID), favicon: favicon)
            }
        }
        return infos
    }

    /// A workspace's band item (`SidebarItemInfo(workspaceRow:color:)`) with the row's status; the selection marks it
    /// active (SidebarModel.selectedItem).
    static func workspaceInfo(_ workspace: WorkspaceModel, machine: MachineID,
                              favicon: (WorkspaceModel, TabModel) -> SidebarFavicon? = { _, _ in nil }) -> SidebarItemInfo {
        // The page face's favicon only: the item keeps its own title rule (the row's name, not the page's).
        let row = SidebarMapping.shared.row(workspace, machine: machine, showsUnread: false, pageFace: { workspace, tab, _ in .init(favicon: favicon(workspace, tab)) },
                                            homeShellTitle: MachineRegistry.isCloudMachineID(machine.rawValue) ? Strings.untitledTerminal : nil)
        var info = SidebarItemInfo(workspaceRow: row, color: SidebarMapping.shared.color(workspace.color))
        info.activity = row.activity
        info.activityStyle = row.activityStyle
        (info.workspace, info.workspaceRow) = (row.id, row) // the row's hover card reads `workspaceRow`
        return info
    }
}
