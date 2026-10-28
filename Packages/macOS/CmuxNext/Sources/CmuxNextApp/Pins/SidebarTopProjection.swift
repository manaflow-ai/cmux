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
    static func workspaceInfos(_ layout: SidebarLayoutDocument, refs: WorkspaceLayoutRefs) -> [LayoutItemRef: SidebarItemInfo] {
        var infos: [LayoutItemRef: SidebarItemInfo] = [:]
        for item in layout.sections.lazy.flatMap(\.items) where item.ref.kind == LayoutItemRef.workspaceKind && infos[item.ref] == nil {
            if let (workspace, daemon) = refs.workspace(for: item.ref) {
                infos[item.ref] = workspaceInfo(workspace, machine: MachineID(daemon.machineID))
            }
        }
        return infos
    }

    /// A workspace's title and the glyph its row stands for (SidebarMapping.row, the one row
    /// rule): the user's symbol (tinted) or emoji, else the user's stored image or the front
    /// page's favicon, else none: text only, no kind glyph or agent brand
    /// (WORKSPACE-ROWS-NO-DEFAULT-ICON), in the workspace's color, with the row's status.
    /// The selection marks it active (SidebarModel.selectedItem).
    static func workspaceInfo(_ workspace: WorkspaceModel, machine: MachineID) -> SidebarItemInfo {
        let row = SidebarMapping.shared.row(workspace, machine: machine, showsUnread: false)
        var info = glyphInfo(row, color: SidebarMapping.shared.color(workspace.color))
        info.activity = row.activity
        info.activityStyle = row.activityStyle
        info.workspace = row.id
        return info
    }

    private static func glyphInfo(_ row: SidebarWorkspace, color: GroupColor?) -> SidebarItemInfo {
        switch row.icon {
        case .symbol(let name, let tint)?: return SidebarItemInfo(title: row.title, symbol: name, color: tint)
        case .emoji(let text, let chip)?: return SidebarItemInfo(title: row.title, symbol: "face.smiling", color: chip, emoji: text)
        case .favicon(let image)?:
            var info = SidebarItemInfo(title: row.title, symbol: "globe", color: color)
            info.favicon = image
            return info
        case .swatch?:
            // The workspace's color as its list row draws it: a dot before the title (SidebarItemRowView).
            var info = SidebarItemInfo(title: row.title, symbol: "textformat", color: color)
            info.textOnly = true
            return info
        case nil:
            // No icon and no color shown (none set, or Show Workspace Colors off): the title alone.
            var info = SidebarItemInfo(title: row.title, symbol: "textformat", color: nil)
            info.textOnly = true
            return info
        }
    }
}
