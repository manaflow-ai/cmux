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

    /// A workspace's title and the glyph its row stands for: the user's
    /// symbol (tinted), else the mark of the agent in its front tab, else its
    /// front tab's kind glyph (SidebarMapping.row, the one row rule), in the
    /// workspace's color. The selection marks it active (SidebarModel.selectedItem).
    static func workspaceInfo(_ workspace: WorkspaceModel) -> SidebarItemInfo {
        let row = SidebarMapping.shared.row(workspace, machine: .local, showsUnread: false)
        let color = SidebarMapping.shared.color(workspace.color)
        switch row.icon {
        case .symbol(let name, let tint)?: return SidebarItemInfo(title: row.title, symbol: name, color: tint)
        case .emoji(let text, let chip)?: return SidebarItemInfo(title: row.title, symbol: "face.smiling", color: chip, emoji: text)
        default: break
        }
        let icon = row.kind.iconName
        let symbol = IconCatalog.bundled.entry(for: icon)?.sf ?? "square.stack"
        return SidebarItemInfo(title: row.title, symbol: symbol, icon: icon, color: color, brand: row.kindBrand)
    }
}
