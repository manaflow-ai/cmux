public import CmuxMobileHost
public import CmuxNextDaemon

/// Projects the daemon's tree onto `workspace:<host>` state (a0-rpc.md 5.2,
/// b5-mac-host.md section 6). Ids are the daemon's durable public resource
/// ids (`ws_…`, `pane_…`, `tab_…`, `term_…`); an entity without one is not
/// addressable from the phone and is left out. Arrangement only: selection,
/// focus and sizes are view state and never leave the Mac.
public struct MobileTreeProjection: Sendable {
    public let hostID: String

    public init(hostID: String) {
        self.hostID = hostID
    }

    /// The phone's state. With `personal` (the home session's `list-personal`,
    /// `profiles-v1`) and this daemon's `sessionID`, workspaces follow the
    /// personal sidebar order and groups, as the Mac sidebar shows them;
    /// otherwise the tree order and its shared groups (`workspace-groups-v1`).
    public func state(_ tree: DaemonTree, personal: PersonalState? = nil, sessionID: String? = nil) -> MobileWorkspaceState {
        let live = tree.workspaces.filter { !$0.isHome && $0.resourceID != nil }
        let groupSnapshots: [WorkspaceGroupSnapshot]
        let groupOf: (WorkspaceSnapshot) -> WorkspaceGroupID?
        var ordered = live
        if let personal, let sessionID {
            let rows = Dictionary(personal.workspaces.filter { $0.sessionID == sessionID }.map { ($0.workspaceKey, $0) },
                                  uniquingKeysWith: { first, _ in first })
            groupSnapshots = personal.groups.sorted { $0.index < $1.index }
            groupOf = { $0.key.flatMap { rows[$0] }?.group }
            // Rows without a personal row follow in session order.
            ordered = live.enumerated().sorted { a, b in
                let ra = a.element.key.flatMap { rows[$0] }?.index ?? Int.max
                let rb = b.element.key.flatMap { rows[$0] }?.index ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
        } else {
            groupSnapshots = tree.groups.sorted { $0.index < $1.index }
            groupOf = { $0.group }
        }
        let groups = groupSnapshots.enumerated().map { MobileWorkspaceGroup(id: $1.id.rawValue, name: $1.name, order: $0) }
        let groupByID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var workspaces: [MobileWorkspace] = []
        for (order, workspace) in ordered.enumerated() {
            guard let id = workspace.resourceID?.rawValue else { continue }
            let panes = workspace.screens.flatMap(\.panes).compactMap(pane)
            workspaces.append(MobileWorkspace(id: id, name: workspace.displayName, color: Self.wireColor(workspace.color),
                                              icon: Self.wireIcon(workspace.icon), pinned: workspace.pinned ? true : nil,
                                              order: order, group: groupOf(workspace).flatMap { groupByID[$0.rawValue] },
                                              panes: panes))
        }
        return MobileWorkspaceState(host: hostID, workspaces: workspaces, groups: groups.isEmpty ? nil : groups)
    }

    /// The color as the wire takes it: a palette token or `#RRGGBB` (an
    /// alpha channel is dropped); anything else is left out.
    static func wireColor(_ color: String?) -> String? {
        guard let color else { return nil }
        let bytes = Array(color.utf8)
        if bytes.first == UInt8(ascii: "#") {
            let hex = bytes.dropFirst()
            guard hex.count == 6 || hex.count == 8, hex.allSatisfy({ isHexDigit($0) }) else { return nil }
            return String(color.prefix(7))
        }
        guard let first = bytes.first, (0x61...0x7A).contains(first), bytes.count <= 32,
              bytes.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "-") }) else {
            return nil
        }
        return color
    }

    /// An SF Symbol name (`[a-z0-9.]{1,128}`); an emoji or anything else is left out.
    static func wireIcon(_ icon: String?) -> String? {
        guard let icon, (1...128).contains(icon.utf8.count),
              icon.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: ".") }) else {
            return nil
        }
        return icon
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte | 0x20)
    }

    /// The personal order index for a workspace that should land at `index`
    /// among the other members of section `group` (nil: ungrouped) of this
    /// session: `workspace.place` removes the row and inserts it at the
    /// returned position of the full personal order (every session's rows).
    /// nil when the workspace has no personal row.
    public func personalPlacementIndex(of key: WorkspaceKey, group: WorkspaceGroupID?, index: Int,
                                       personal: PersonalState, sessionID: String) -> Int? {
        let rows = personal.workspaces.sorted { $0.index < $1.index }
        guard let old = rows.firstIndex(where: { $0.sessionID == sessionID && $0.workspaceKey == key }) else { return nil }
        var rest = rows
        rest.remove(at: old)
        let members = rest.indices.filter { rest[$0].sessionID == sessionID && rest[$0].group == group }
        if members.isEmpty { return min(old, rest.count) }
        if index < members.count { return members[index] }
        return members[members.count - 1] + 1
    }

    private func pane(_ pane: PaneSnapshot) -> MobilePane? {
        guard !pane.dead, let id = pane.resourceID?.rawValue else { return nil }
        return MobilePane(id: id, tabs: pane.tabs.compactMap(tab))
    }

    private func tab(_ tab: TabSnapshot) -> MobileTab? {
        guard let id = tab.tabResourceID?.rawValue else { return nil }
        let kind: MobileTab.Kind
        var terminal: String?
        var url: String?
        switch tab.kind {
        case .pty:
            kind = .terminal
            terminal = tab.terminalResourceID?.rawValue
        case .browser:
            kind = .browser
            url = tab.url
        case .conversation:
            kind = .agent
        case .remoteTerminal, .other:
            kind = .other
        }
        let unread = tab.notification?.unread == true ? 1 : 0
        let status: MobileTab.Status = tab.dead ? .error : .idle
        return MobileTab(id: id, kind: kind, title: tab.displayTitle, terminal: terminal, url: url,
                         status: status, unread: unread)
    }

    /// The tab whose terminal is `terminal` (`term_…`), with the tree's generation.
    public func tab(showing terminal: String, in tree: DaemonTree) -> TabSnapshot? {
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.terminalResourceID?.rawValue == terminal }) { return tab }
            }
        }
        return nil
    }

    public func workspaceKey(_ id: String, in tree: DaemonTree) -> WorkspaceKey? {
        tree.workspaces.first { $0.resourceID?.rawValue == id }?.key
    }

    public func surface(ofTab id: String, in tree: DaemonTree) -> SurfaceID? {
        for workspace in tree.workspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                if let tab = pane.tabs.first(where: { $0.tabResourceID?.rawValue == id }) { return tab.surface }
            }
        }
        return nil
    }
}
