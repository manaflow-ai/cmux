import AppKit

/// What VoiceOver reaches on a group's header, for the one row a group draws as (`SidebarLayout+SoleMember`): the
/// header's expanded state and its editor, menu, New Workspace and fold actions, beside the workspace's own.
struct StandingGroupAccess {
    var expanded: Bool
    var toggle: () -> Void
    var edit: () -> Void
    var menu: () -> Void
    var add: (() -> Void)?
}

/// One of the header actions a sole-member row offers (`StandingGroupAccess`). A value, not a closure: a VoiceOver
/// action holds only Sendable state and resolves the row's current access when it is performed.
enum StandingGroupAction: Sendable {
    case edit, menu, add
    /// The fold for the header state the action was built with: it refuses once the group folded the other way.
    case fold(expanded: Bool)

    var name: String {
        switch self {
        case .edit: GroupEditorStrings.editor
        case .menu: GroupEditorStrings.moreActions
        case .add: GroupEditorStrings.newWorkspace
        case let .fold(expanded): expanded ? GroupEditorStrings.collapse : GroupEditorStrings.expand
        }
    }

    func perform(on access: StandingGroupAccess) -> Bool {
        switch self {
        case .edit: access.edit()
        case .menu: access.menu()
        case .add:
            guard let add = access.add else { return false }
            add()
        case let .fold(expanded):
            guard access.expanded == expanded else { return false }
            access.toggle()
        }
        return true
    }
}

extension WorkspaceRowView {
    /// Routes AXPress through the sidebar's shared workspace selection action.
    override func accessibilityPerformPress() -> Bool {
        guard !isShowingPlaceholder, let onSelect else { return false }
        onSelect()
        return true
    }

    /// The session tree's fold and the row's menu: the more button shows only on hover
    /// (Lawrence 2026-10-11), and a hidden button leaves the accessibility tree.
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        var actions = super.accessibilityCustomActions() ?? []
        guard !isShowingPlaceholder else { return actions.isEmpty ? nil : actions }
        // VoiceOver may retain an action after the list recycles this view for another workspace.
        // Resolve the current callback only while this row still represents the action's workspace.
        let actionKey = key
        if let treeFold, onToggleTree != nil {
            let name = treeFold == .collapsed ? Strings.expandSessions : Strings.collapseSessions
            actions.append(NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self, self.canPerformAccessibilityAction(for: actionKey), self.treeFold == treeFold,
                      let onToggleTree = self.onToggleTree else { return false }
                onToggleTree()
                return true
            })
        }
        if onMore != nil {
            actions.append(NSAccessibilityCustomAction(name: Strings.workspaceMenu) { [weak self] in
                guard let self, self.canPerformAccessibilityAction(for: actionKey), let onMore = self.onMore else { return false }
                onMore()
                return true
            })
        }
        if let group = standingGroup {
            var groupActions: [StandingGroupAction] = [.edit, .menu]
            if group.add != nil { groupActions.append(.add) }
            groupActions.append(.fold(expanded: group.expanded))
            for action in groupActions { actions.append(standingGroupAction(action, for: actionKey)) }
        }
        return actions.isEmpty ? nil : actions
    }

    /// The handler captures only Sendable values (the row weakly, its key, the action) and reads the row's current
    /// `standingGroup` when performed. A captured closure parameter is task-isolated to the main-actor handler, which
    /// the Release compile (Xcode 26.6) refuses as a send.
    private func standingGroupAction(_ action: StandingGroupAction, for actionKey: SidebarRowKey) -> NSAccessibilityCustomAction {
        NSAccessibilityCustomAction(name: action.name) { [weak self] in
            guard let self, self.canPerformAccessibilityAction(for: actionKey),
                  let current = self.standingGroup else { return false }
            return action.perform(on: current)
        }
    }

    private func canPerformAccessibilityAction(for actionKey: SidebarRowKey) -> Bool {
        key == actionKey && !isHidden && !isShowingPlaceholder
    }

    func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent, title: String? = nil) -> String {
        Self.accessibilityText(ws, content: content, tabCount: count, presence: presenceDots.isHidden ? [] : presenceDots.presence,
                               title: title)
    }

    /// The row's label: what it draws, in reading order. `tabCount` and `presence` are what the
    /// row's tab count and presence dots show (nil and empty when hidden). `title` is the name the
    /// row reads (`SidebarWorkspace.spokenRowTitle`), nil for the workspace's.
    static func accessibilityText(_ ws: SidebarWorkspace, content: WorkspaceRowContent, tabCount count: Int?,
                                  presence: [SidebarPresence], title: String? = nil) -> String {
        var parts = [title ?? ws.title]
        let detail = content.now.map(Strings.rowNow) ?? content.detail
        if let detail { parts.append(detail) }
        // The chip's word (never drawn: no status words on a row), else the one-line status the row draws.
        if let s = content.chip.map({ SidebarPriorityRowView.chipText($0, now: Date()) }) ?? content.trailingStatus { parts.append(s) }
        if let s = content.status?.searchText, !s.isEmpty { parts.append(s) }
        if let s = content.badge { parts.append(s) }
        if let badge = content.pullRequests { parts.append(Strings.pullRequests(badge)) }
        if let rollUp = content.rollUp { parts.append(Strings.rollUp(rollUp)) }
        if let value = content.progress?.value { parts.append(Strings.progressPercent(Int((value * 100).rounded()))) }
        if let count { parts.append(Strings.tabCount(count)) }
        switch ws.unread {
        case let .count(n) where n > 0: parts.append(Strings.unreadCount(n))
        case .dot: parts.append(Strings.unreadDot)
        default: break
        }
        if let text = Strings.activity(content.activity) { parts.append(text) }
        if ws.muted { parts.append(Strings.notificationsMuted) }
        parts += ws.usageWarnings
        // The computer: a one-list row on another computer says it with its status when it cannot connect
        // (`SidebarLayout.machineLabel`, "gpu-box · Failed to start"), whether or not the row draws a mark
        // (with one machine listed it draws none). No line draws it (Leo 2026-10-30: "remove the second
        // line"), and the detail now holds only the facts the person turned on, so it is said on its own,
        // never matched against them: a branch named like the machine is no proof the machine was said
        // (review of #28510 at 4acab8c2).
        if let spoken = content.machineLabel ?? content.machine?.name { parts.append(spoken) }
        parts += presence.map(Strings.presenceLine)
        return parts.joined(separator: ", ")
    }
}
