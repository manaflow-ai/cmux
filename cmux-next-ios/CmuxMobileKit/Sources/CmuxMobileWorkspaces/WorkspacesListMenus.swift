#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI
import UIKit

private let theme = CmuxMobileTheme.standard

/// The Workspaces list's long-press menus as UIKit menus, built when one
/// opens (`contextMenuConfigurationForItemsAt`) from the list as it is then.
/// A SwiftUI `.contextMenu` on every row built each row's whole menu (the
/// Mac's row order, nine swatches, every tab) on every pass.
extension WorkspacesList {
    /// A row's menu: the Mac and branch as its header, the workspace's tabs
    /// (jump straight to one), then the Mac's sidebar row actions (pin, color,
    /// order, read marks), Rename and Close, and the bulk closes.
    func rowMenu(_ workspaceID: String) -> UIMenu? {
        let inbox = inbox
        guard let ws = inbox.workspace(workspaceID) else { return nil }
        let status = inbox.status(ws)
        let canManage = status != .offline && creator.canManage(ws)
        let macName = mac(ws.macID).map(displayName) ?? "Unknown Mac"
        var header: [UIMenuElement] = []
        if status == .offline {
            if scope == .all {
                header.append(action("Show \(macName)", "line.3.horizontal.decrease") { select(.mac(ws.macID)) })
            }
        } else {
            for tab in ws.tabs {
                // An agent tab by its task (as on the row), the agent as the subtitle.
                let title = tab.isAgent ? (tab.task ?? tab.title) : tab.title
                let item = action(title, tab.systemImage) { openWorkspace(ws, status: status, tab: tab) }
                if tab.isAgent, tab.task != nil { item.subtitle = tab.agentName }
                header.append(item)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: menuHeader(ws, macName: macName, offline: status == .offline),
                                                options: .displayInline, children: header)]
        if canManage {
            if creator.canArrange(ws) { children.append(arrangeMenu(ws, inbox: inbox)) }
            var manage: [UIMenuElement] = [action("Rename", "pencil") { startRename(ws) }]
            if creator.canDuplicate(ws) {
                manage.append(action(WorkspaceCreator.duplicateTitle, "plus.square.on.square") { creator.duplicate(ws) })
            }
            manage.append(action("Close Workspace", "xmark", destructive: true) { confirmClose(ws) })
            if let bulk = bulkCloseMenu(ws, inbox: inbox) { manage.append(bulk) }
            children.append(UIMenu(options: .displayInline, children: manage))
        }
        return UIMenu(children: children)
    }

    /// Pin Workspace; Appearance (Set Workspace Color…, Reset Workspace Color,
    /// Set Icon…, Remove Icon); Options (Mark as Read / Unread, Clear Workspace
    /// Name); Group; Move (Move Workspace Up / Down).
    private func arrangeMenu(_ ws: Workspace, inbox: WorkspaceInbox) -> UIMenu {
        let order = inbox.macOrder(of: ws)
        var items: [UIMenuElement] = [
            action(ws.isPinned ? "Unpin Workspace" : "Pin Workspace", ws.isPinned ? "pin.slash" : "pin") {
                theme.haptics.selection()
                withAnimation(theme.motion.smooth.animation) { creator.setPinned(ws, !ws.isPinned) }
            },
        ]
        let colors = WorkspaceColor.allCases.map { color in
            WorkspaceColor(stored: ws.colorHex) == color
                ? action(color.title, "checkmark") { creator.setColor(ws, color) }
                : UIAction(title: color.title, image: WorkspaceSwatch.uiImage(color)) { _ in creator.setColor(ws, color) }
        }
        var appearance: [UIMenuElement] = [UIMenu(title: "Set Workspace Color…", image: UIImage(systemName: "paintpalette"), children: colors)]
        if ws.colorHex != nil { appearance.append(action("Reset Workspace Color", "circle.slash") { creator.setColor(ws, nil) }) }
        var icons: [UIMenuElement] = WorkspaceIcon.symbols.map { symbol in
            action(symbol, ws.icon == symbol ? "checkmark" : symbol) { creator.setIcon(ws, symbol) }
        }
        icons.append(action("Emoji…", "face.smiling") { startIconEmoji(ws) })
        appearance.append(UIMenu(title: "Set Icon…", image: UIImage(systemName: "app.badge"), children: icons))
        if ws.icon != nil { appearance.append(action("Remove Icon", "minus.circle") { creator.setIcon(ws, nil) }) }
        items.append(UIMenu(title: "Appearance", image: UIImage(systemName: "paintbrush"), children: appearance))
        var options: [UIMenuElement] = [
            ws.hasUnread
                ? action("Mark Workspace as Read", "envelope.open") { creator.setUnread(ws, false) }
                : action("Mark Workspace as Unread", "envelope.badge") { creator.setUnread(ws, true) },
        ]
        if ws.hasCustomTitle { options.append(action("Clear Workspace Name", "textformat") { creator.clearName(ws) }) }
        items.append(UIMenu(title: "Options", image: UIImage(systemName: "ellipsis.circle"), children: options))
        if let group = groupFolder(ws) { items.append(group) }
        if order.count > 1 {
            let up = action("Move Workspace Up", "arrow.up") {
                withAnimation(theme.motion.smooth.animation) { creator.move(ws, by: -1, among: order) }
            }
            if order.first?.id == ws.id { up.attributes.insert(.disabled) }
            let down = action("Move Workspace Down", "arrow.down") {
                withAnimation(theme.motion.smooth.animation) { creator.move(ws, by: 1, among: order) }
            }
            if order.last?.id == ws.id { down.attributes.insert(.disabled) }
            items.append(UIMenu(title: "Move", image: UIImage(systemName: "arrow.up.arrow.down"), children: [up, down]))
        }
        return UIMenu(options: .displayInline, children: items)
    }

    /// Group: Move Workspace to Group… (its groups, then Move Workspace to New
    /// Group) and Remove Workspace from Group.
    private func groupFolder(_ ws: Workspace) -> UIMenu? {
        guard creator.canGroup(ws) else { return nil }
        let choices = creator.groupChoices(for: ws)
        var move: [UIMenuElement] = choices.map { group in
            UIAction(title: group.displayName, image: WorkspaceColor(stored: group.color).map(WorkspaceSwatch.uiImage)) { _ in
                withAnimation(theme.motion.smooth.animation) { creator.place(ws, in: group) }
            }
        }
        let newGroup = action("Move Workspace to New Group", "folder.badge.plus") { startNewGroup(ws) }
        move.append(choices.isEmpty ? newGroup : UIMenu(options: .displayInline, children: [newGroup]))
        var items: [UIMenuElement] = [UIMenu(title: "Move Workspace to Group…", image: UIImage(systemName: "folder.badge.questionmark"), children: move)]
        if ws.group != nil {
            items.append(action("Remove Workspace from Group", "folder.badge.minus") {
                withAnimation(theme.motion.smooth.animation) { creator.place(ws, in: nil) }
            })
        }
        return UIMenu(title: "Group", image: UIImage(systemName: "folder"), children: items)
    }

    /// Close Other Workspaces / Above / Below, over the Mac's sidebar order of
    /// this workspace's Mac. The phone asks first (the Mac closes at once).
    private func bulkCloseMenu(_ ws: Workspace, inbox: WorkspaceInbox) -> UIMenu? {
        let order = inbox.macSidebar(ws.macID).filter { creator.canManage($0) }
        // The Mac's Close folder order: Other, Below, Above.
        let kinds = [WorkspaceBulkClose.others, .below, .above].filter { !$0.targets(of: ws, in: order).isEmpty }
        guard !kinds.isEmpty else { return nil }
        let items = kinds.map { kind in
            UIAction(title: kind.title, attributes: .destructive) { _ in
                confirmBulkClose(BulkClose(kind: kind, workspace: ws, targets: kind.targets(of: ws, in: order)))
            }
        }
        return UIMenu(title: "Close", image: UIImage(systemName: "xmark.square"), children: items)
    }

    /// A group header's menu: Rename Group…, Set Workspace Group Color…,
    /// Collapse / Expand Workspace Group, then Ungroup Workspaces and Delete Group.
    func groupMenu(_ header: WorkspaceGroupHeaderModel) -> UIMenu? {
        guard header.canEdit else { return nil }
        let (group, macID) = (header.group, header.macID)
        let colors = WorkspaceColor.allCases.map { color in
            WorkspaceColor(stored: group.color) == color
                ? action(color.title, "checkmark") { creator.setGroupColor(group, on: macID, color) }
                : UIAction(title: color.title, image: WorkspaceSwatch.uiImage(color)) { _ in creator.setGroupColor(group, on: macID, color) }
        }
        let edit = UIMenu(title: group.displayName, options: .displayInline, children: [
            action("Rename Group…", "pencil.line") { startRenameGroup(group, macID: macID) },
            UIMenu(title: "Set Workspace Group Color…", image: UIImage(systemName: "paintpalette"), children: colors),
            action(group.isCollapsed ? "Expand Workspace Group" : "Collapse Workspace Group",
                   group.isCollapsed ? "chevron.down" : "chevron.right") {
                withAnimation(theme.motion.smooth.animation) { creator.setGroupCollapsed(group, on: macID, !group.isCollapsed) }
            },
        ])
        let remove = UIMenu(options: .displayInline, children: [
            action("Ungroup Workspaces", "rectangle.stack.badge.minus") {
                withAnimation(theme.motion.smooth.animation) { creator.deleteGroup(group, on: macID) }
            },
            action("Delete Group", "trash", destructive: true) { confirmDeleteGroup(GroupTarget(group: group, macID: macID)) },
        ])
        return UIMenu(children: [edit, remove])
    }

    private func action(_ title: String, _ symbol: String, destructive: Bool = false, _ run: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { _ in run() }
    }
}
#endif
