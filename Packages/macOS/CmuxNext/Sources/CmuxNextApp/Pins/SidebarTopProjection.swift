import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextIcons
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
            return SidebarMembership.pinnedFirst(filtered, pinned: pinned)
        case .layout(let hidden):
            return SidebarMembership.hiding(filtered, workspaces: hidden)
        }
    }
}

/// How workspace tiles and top rows draw.
@MainActor
struct SidebarWorkspaceItems {
    /// How each open workspace a layout item names draws; a ref with no
    /// entry is closed or another device's (drawn dimmed by the fallback).
    static func workspaceInfos(_ layout: SidebarLayoutDocument, refs: WorkspaceLayoutRefs) -> [LayoutItemRef: SidebarItemInfo] {
        var infos: [LayoutItemRef: SidebarItemInfo] = [:]
        for item in layout.sections.lazy.flatMap(\.items) where item.ref.kind == LayoutItemRef.workspaceKind && infos[item.ref] == nil {
            if let (workspace, _) = refs.workspace(for: item.ref) { infos[item.ref] = workspaceInfo(workspace) }
        }
        return infos
    }

    /// A workspace's title, its chosen symbol (else the workspace glyph) and
    /// color. The selection marks it active (SidebarModel.selectedItem).
    static func workspaceInfo(_ workspace: WorkspaceModel) -> SidebarItemInfo {
        let color = workspace.color.flatMap(GroupColor.init(rawValue:))
        if case .symbol(let name, let tint)? = workspace.icon.flatMap({ WorkspaceIcon.parse($0, color: color) }) {
            return SidebarItemInfo(title: workspace.displayName, symbol: name, color: tint)
        }
        let symbol = IconCatalog.bundled.entry(for: .workspace)?.sf ?? "square.stack"
        return SidebarItemInfo(title: workspace.displayName, symbol: symbol, icon: .workspace, color: color)
    }
}
