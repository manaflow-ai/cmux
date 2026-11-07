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
    static func workspaceInfos(_ layout: SidebarLayoutDocument, refs: WorkspaceLayoutRefs, autoNames: Bool = true, favicon: @escaping (WorkspaceModel, TabModel) -> SidebarFavicon? = { _, _ in nil },
                               faces: SidebarFaceBatch? = nil) -> [LayoutItemRef: SidebarItemInfo] {
        var seen = Set<LayoutItemRef>()
        let items = layout.sections.flatMap(\.items).filter { $0.ref.kind == LayoutItemRef.workspaceKind && seen.insert($0.ref).inserted }
            .compactMap { item in refs.workspace(for: item.ref).map { (ref: item.ref, workspace: $0.0, machine: MachineID($0.1.machineID)) } }
        let infos = SidebarMapping.shared.tileInfos(items.map { ($0.workspace, $0.machine) }, favicon: favicon, homeShellTitle: homeShellTitle(autoNames), faces: faces)
        return Dictionary(zip(items.map(\.ref), infos), uniquingKeysWith: { first, _ in first })
    }

    /// A workspace's band item (`SidebarItemInfo(workspaceRow:color:)`) with the row's status; the selection marks it
    /// active (SidebarModel.selectedItem).
    static func workspaceInfo(_ workspace: WorkspaceModel, machine: MachineID, autoNames: Bool = true,
                              favicon: @escaping (WorkspaceModel, TabModel) -> SidebarFavicon? = { _, _ in nil }) -> SidebarItemInfo {
        SidebarMapping.shared.tileInfos([(workspace, machine)], favicon: favicon, homeShellTitle: homeShellTitle(autoNames)).first
            ?? SidebarItemInfo(workspaceRow: SidebarMapping.unmapped(workspace, machine: machine), color: nil)
    }

    /// A Cloud machine's unnamed workspace whose shell idles at its home reads "Terminal" while workspaces auto-name.
    private static func homeShellTitle(_ autoNames: Bool) -> (MachineID) -> String? {
        { autoNames && MachineRegistry.isCloudMachineID($0.rawValue) ? Strings.untitledTerminal : nil }
    }
}
