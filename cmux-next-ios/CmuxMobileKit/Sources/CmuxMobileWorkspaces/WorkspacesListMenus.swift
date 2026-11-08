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
        // Settings → Long-Press Menus: the items the person hid stay out.
        let shown = CmuxMobileMenuCustomization.hidden()
        func offered(_ item: String) -> Bool { !shown.contains("workspaceRow.\(item)") }
        var header: [UIMenuElement] = []
        if status == .offline {
            if scope == .all {
                header.append(action("Show \(macName)", "line.3.horizontal.decrease") { select(.mac(ws.macID)) })
            }
        } else if offered("tabs") {
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
        // Send Message… (the Mac's row action): a message to the Chief with a link to this workspace.
        if status != .offline, offered("sendMessage"), ChiefMessenger.shared.isAvailable, let subject = ChiefMessageAbout(workspace: ws) {
            children.append(UIMenu(options: .displayInline, children: [
                action("Send Message…", "paperplane") { ChiefMessenger.shared.messageAbout(subject) },
            ]))
        }
        // The Mac's Copy rows (Copy Workspace Link, Copy Workspace ID, Copy Workspace ID and
        // Ref), each only when the Mac sent the workspace's public id.
        if status != .offline {
            let rows: [(title: String, symbol: String, text: String?)] = [
                ("Copy Workspace Link", "link", ws.copyLinkText),
                ("Copy Workspace ID", "number", ws.copyIDText),
                ("Copy Workspace ID and Ref", "number.square", ws.copyIDAndRefText),
            ]
            var copies: [UIMenuElement] = []
            for row in rows {
                guard let text = row.text else { continue }
                copies.append(action(row.title, row.symbol) { UIPasteboard.general.string = text })
            }
            if !copies.isEmpty {
                children.append(UIMenu(title: "Copy", image: UIImage(systemName: "doc.on.doc"), children: copies))
            }
        }
        if canManage {
            if creator.canArrange(ws), offered("arrange") { children.append(arrangeMenu(ws, inbox: inbox)) }
            var manage: [UIMenuElement] = []
            if let new = newWorkspaceMenu(ws) { manage.append(new) }
            if offered("rename") { manage.append(action("Rename", "pencil") { startRename(ws) }) }
            if creator.canDuplicate(ws), offered("duplicate") {
                manage.append(action(WorkspaceCreator.duplicateTitle, "plus.square.on.square") { creator.duplicate(ws) })
                // Only a workspace with a page: without one it is the same as Duplicate Workspace.
                if ws.tabs.contains(where: { $0.kind == .browser }) {
                    manage.append(action(WorkspaceCreator.duplicateTerminalsOnlyTitle, "terminal") {
                        creator.duplicate(ws, browsers: false)
                    })
                }
            }
            // Close Workspace is never hidden: the row's swipe has it too, but a menu keeps one way out.
            manage.append(action("Close Workspace", "xmark", destructive: true) { confirmClose(ws) })
            if offered("bulkClose"), let bulk = bulkCloseMenu(ws, inbox: inbox) { manage.append(bulk) }
            children.append(UIMenu(options: .displayInline, children: manage))
        }
        return UIMenu(children: children)
    }

    /// Pin Workspace; Appearance (Set Workspace Color…, Reset Workspace Color,
    /// Set Icon…, Remove Icon, Remove All Workspace Colors); Options (Mark as Read /
    /// Unread, Clear Workspace Name); Group; Move (Move Workspace Up / Down, to Top /
    /// Bottom, Sort Workspaces).
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
        // The Mac's picker: every SF Symbol, searchable, or one emoji.
        appearance.append(action("Set Icon…", ws.icon.flatMap { UIImage(systemName: $0) == nil ? nil : $0 } ?? "app.badge") { startIconPicker(ws) })
        if ws.icon != nil { appearance.append(action("Remove Icon", "minus.circle") { creator.setIcon(ws, nil) }) }
        if let removeAll = removeAllColorsAction(ws.macID) { appearance.append(removeAll) }
        items.append(UIMenu(title: "Appearance", image: UIImage(systemName: "paintbrush"), children: appearance))
        var options: [UIMenuElement] = [
            ws.hasUnread
                ? action("Mark Workspace as Read", "envelope.open") { creator.setUnread(ws, false) }
                : action("Mark Workspace as Unread", "envelope.badge") { creator.setUnread(ws, true) },
        ]
        if ws.hasCustomTitle { options.append(action("Clear Workspace Name", "textformat") { creator.clearName(ws) }) }
        items.append(UIMenu(title: "Options", image: UIImage(systemName: "ellipsis.circle"), children: options))
        if let group = groupFolder(ws) { items.append(group) }
        let container = creator.container(of: ws)
        let sortable = creator.containers(on: ws.macID).contains { $0.count > 1 }
        var move: [UIMenuElement] = []
        if order.count > 1 {
            let up = action("Move Workspace Up", "arrow.up") {
                withAnimation(theme.motion.smooth.animation) { creator.move(ws, by: -1, among: order) }
            }
            if order.first?.id == ws.id { up.attributes.insert(.disabled) }
            let down = action("Move Workspace Down", "arrow.down") {
                withAnimation(theme.motion.smooth.animation) { creator.move(ws, by: 1, among: order) }
            }
            if order.last?.id == ws.id { down.attributes.insert(.disabled) }
            move += [up, down]
        }
        // Move Workspace Above… / Below…: a row of the same container to go next to.
        for side in WorkspaceNeighborMove.allCases {
            let targets = side.targets(for: ws, in: container)
            guard !targets.isEmpty else { continue }
            let choices = targets.map { target in
                UIAction(title: target.title) { _ in
                    withAnimation(theme.motion.smooth.animation) { creator.move(ws, side, target) }
                }
            }
            move.append(UIMenu(title: side.title, image: UIImage(systemName: side.systemImage), children: choices))
        }
        if container.count > 1 {
            for edge in WorkspaceEdge.allCases {
                let item = action(edge.title(grouped: ws.group != nil), edge == .top ? "arrow.up.to.line" : "arrow.down.to.line") {
                    withAnimation(theme.motion.smooth.animation) { creator.move(ws, to: edge) }
                }
                if edge.anchor(of: ws, in: container) == nil { item.attributes.insert(.disabled) }
                move.append(item)
            }
        }
        if sortable {
            let keys = WorkspaceSortKey.allCases.map { key in
                let item = action(key.shortTitle, key.systemImage) {
                    withAnimation(theme.motion.smooth.animation) { creator.sortWorkspaces(on: ws.macID, by: key) }
                }
                item.accessibilityLabel = key.title
                return item
            }
            move.append(UIMenu(title: "Sort Workspaces", image: UIImage(systemName: "arrow.up.arrow.down.square"), children: keys))
        }
        let targets = creator.mergeTargets(for: ws)
        if !targets.isEmpty {
            // Merge Workspace Into…: every tab of this one moves into the chosen workspace.
            let into = targets.map { target in
                UIAction(title: target.title, image: target.icon.flatMap { UIImage(systemName: $0) } ?? UIImage(systemName: "square.on.square")) { _ in
                    theme.haptics.selection()
                    creator.merge(ws, into: target)
                }
            }
            move.append(UIMenu(title: "Merge Workspace Into…", image: UIImage(systemName: "arrow.triangle.merge"), children: into))
        }
        if !move.isEmpty {
            items.append(UIMenu(title: "Move", image: UIImage(systemName: "arrow.up.arrow.down"), children: move))
        }
        return UIMenu(options: .displayInline, children: items)
    }

    /// New ▸ New Workspace Above / Below / at Top / at Bottom (the Mac's row New folder): a new
    /// terminal workspace, opened at once and placed there once the Mac lists it.
    private func newWorkspaceMenu(_ ws: Workspace) -> UIMenu? {
        let placements = creator.newWorkspacePlacements(beside: ws)
        guard !placements.isEmpty else { return nil }
        let items = placements.map { placement in
            action(placement.title, placement.systemImage) { create(.terminal, directory: nil, on: ws.macID, placement: placement) }
        }
        // The Mac's row folder title ("New", `MenuFolder.new`).
        return UIMenu(title: "New", image: UIImage(systemName: "plus.square"), children: items)
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
        // The Mac's Close folder order: Other, Other in Group, Below, Above, All.
        let kinds = [WorkspaceBulkClose.others, .othersInGroup, .below, .above, .all].filter { !$0.targets(of: ws, in: order).isEmpty }
        guard !kinds.isEmpty else { return nil }
        let items = kinds.map { kind in
            UIAction(title: kind.title, attributes: .destructive) { _ in
                confirmBulkClose(BulkClose(kind: kind, workspace: ws, targets: kind.targets(of: ws, in: order)))
            }
        }
        return UIMenu(title: "Close", image: UIImage(systemName: "xmark.square"), children: items)
    }

    /// A group header's menu: Rename Group…, Set Workspace Group Color…,
    /// Collapse / Expand Workspace Group, Options, then Ungroup Workspaces, Close All in
    /// Group, Close Other Groups and Delete Group.
    func groupMenu(_ header: WorkspaceGroupHeaderModel) -> UIMenu? {
        guard header.canEdit else { return nil }
        let (group, macID) = (header.group, header.macID)
        let newInGroup = action(NewWorkspacePlacement.inGroup(group).title, NewWorkspacePlacement.inGroup(group).systemImage) {
            create(.terminal, directory: nil, on: macID, placement: .inGroup(group))
        }
        // A group the Mac lists with no workspace: New Workspace in Group and Delete Group.
        guard header.count > 0 else {
            return UIMenu(children: [
                UIMenu(title: group.displayName, options: .displayInline, children: [newInGroup]),
                UIMenu(options: .displayInline, children: [
                    action("Delete Group", "trash", destructive: true) {
                        withAnimation(theme.motion.smooth.animation) { creator.deleteEmptyGroup(group, on: macID) }
                    },
                ]),
            ])
        }
        let colors = WorkspaceColor.allCases.map { color in
            WorkspaceColor(stored: group.color) == color
                ? action(color.title, "checkmark") { creator.setGroupColor(group, on: macID, color) }
                : UIAction(title: color.title, image: WorkspaceSwatch.uiImage(color)) { _ in creator.setGroupColor(group, on: macID, color) }
        }
        var editItems: [UIMenuElement] = [
            action("Rename Group…", "pencil.line") { startRenameGroup(group, macID: macID) },
            UIMenu(title: "Set Workspace Group Color…", image: UIImage(systemName: "paintpalette"), children: colors),
            action(group.isCollapsed ? "Expand Workspace Group" : "Collapse Workspace Group",
                   group.isCollapsed ? "chevron.down" : "chevron.right") {
                withAnimation(theme.motion.smooth.animation) { creator.setGroupCollapsed(group, on: macID, !group.isCollapsed) }
            },
        ]
        if let options = groupOptions(group, macID: macID) { editItems.append(options) }
        editItems.insert(newInGroup, at: 0)
        if creator.members(of: [group], on: macID).allSatisfy({ creator.canDuplicate($0) }) {
            editItems.append(action("Duplicate Workspace Group", "plus.square.on.square") {
                theme.haptics.selection()
                creator.duplicateGroup(group, on: macID)
            })
        }
        let edit = UIMenu(title: group.displayName, options: .displayInline, children: editItems)
        var removeItems: [UIMenuElement] = [
            action("Ungroup Workspaces", "rectangle.stack.badge.minus") {
                withAnimation(theme.motion.smooth.animation) { creator.deleteGroup(group, on: macID) }
            },
        ]
        removeItems += groupCloses(group, macID: macID)
        removeItems.append(action("Delete Group", "trash", destructive: true) { confirmDeleteGroup(GroupTarget(group: group, macID: macID)) })
        let remove = UIMenu(options: .displayInline, children: removeItems)
        return UIMenu(children: [edit, remove])
    }

    /// The Mac's group Options folder: Collapse Others, Collapse All Groups, Expand All Groups,
    /// and Remove All Workspace Colors.
    private func groupOptions(_ group: MacWorkspaceGroup, macID: String) -> UIMenu? {
        let groups = creator.shownGroups(on: macID)
        var items: [UIMenuElement] = []
        if groups.count > 1, creator.canCollapseOthers(keeping: group, on: macID) {
            items.append(action("Collapse Others", "arrow.down.forward.and.arrow.up.backward") {
                withAnimation(theme.motion.smooth.animation) { creator.collapseOtherGroups(keeping: group, on: macID) }
            })
        }
        if groups.contains(where: { !$0.isCollapsed }) {
            items.append(action("Collapse All Groups", "rectangle.compress.vertical") {
                withAnimation(theme.motion.smooth.animation) { creator.setAllGroupsCollapsed(on: macID, true) }
            })
        }
        if groups.contains(where: \.isCollapsed) {
            items.append(action("Expand All Groups", "rectangle.expand.vertical") {
                withAnimation(theme.motion.smooth.animation) { creator.setAllGroupsCollapsed(on: macID, false) }
            })
        }
        if let removeAll = removeAllColorsAction(macID) { items.append(removeAll) }
        guard !items.isEmpty else { return nil }
        return UIMenu(title: "Options", image: UIImage(systemName: "ellipsis.circle"), children: items)
    }

    /// Remove All Workspace Colors: every workspace of the Mac (the Mac also clears its groups'
    /// colors; a phone may not, see `WorkspaceCreator.removeAllColors`).
    private func removeAllColorsAction(_ macID: String) -> UIAction? {
        guard creator.hasColors(on: macID) else { return nil }
        return action("Remove All Workspace Colors", "circle.slash") {
            withAnimation(theme.motion.smooth.animation) { creator.removeAllColors(on: macID) }
        }
    }

    /// Close All in Group and Close Other Groups. The phone asks first, as for every close of
    /// several workspaces.
    private func groupCloses(_ group: MacWorkspaceGroup, macID: String) -> [UIMenuElement] {
        var items: [UIMenuElement] = []
        let members = creator.members(of: [group], on: macID)
        if let first = members.first {
            items.append(action("Close All in Group", "xmark.square", destructive: true) {
                confirmBulkClose(BulkClose(kind: .all, workspace: first, targets: members, groups: [group]))
            })
        }
        let others = creator.shownGroups(on: macID).filter { $0.id != group.id }
        let closing = creator.members(of: others, on: macID)
        if let first = closing.first {
            items.append(action("Close Other Groups", "xmark.circle", destructive: true) {
                confirmBulkClose(BulkClose(kind: .others, workspace: first, targets: closing, groups: others))
            })
        }
        return items
    }

    private func action(_ title: String, _ symbol: String, destructive: Bool = false, _ run: @escaping () -> Void) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { _ in run() }
    }
}
#endif
