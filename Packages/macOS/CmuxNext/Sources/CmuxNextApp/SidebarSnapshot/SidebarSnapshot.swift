import CmuxNextDesign
import CmuxNextSidebar
import Foundation
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextOracle
import CryptoKit
#endif

/// One window's sidebar as it last looked, saved so the next launch draws
/// it in the first frame (snapshot-first launch): sections, groups and the
/// title and icon of each row, plus the space (profile) bar. Live-only
/// detail (status lines, activity, unread counts, cwd) is never saved; it
/// arrives with the daemon. Rows read back as `SidebarRowState.stale`.
nonisolated struct SidebarSnapshot: Codable, Hashable, Sendable {
    var sections: [Section]
    var profiles: [Profile]
    var activeProfileID: String?

    struct Section: Codable, Hashable, Sendable {
        /// Nil for the pinned section.
        var machineID: String?
        var machineName: String?
        /// `local`, `cloud` or `ssh`.
        var machineKind: String?
        var isCollapsed: Bool
        var nodes: [Node]
    }

    /// A loose workspace, or a group with its workspaces.
    struct Node: Codable, Hashable, Sendable {
        var workspace: Workspace?
        var group: Group?
    }

    struct Workspace: Codable, Hashable, Sendable {
        var id: String
        var machineID: String
        var title: String
        /// `harness`, `browser` or `terminal`; absent in older snapshots.
        var kind: String?
        /// The agent brand whose mark is the row's type glyph; absent in older snapshots.
        var kindBrand: String?
        /// `symbol:<name>`, `swatch:<color>` or `emoji:<text>`.
        var icon: String?
        var iconTint: String?
    }

    struct Group: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var color: String
        var isCollapsed: Bool
        var isPinned: Bool
        var workspaces: [Workspace]
    }

    struct Profile: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var color: String?
        var icon: String?
    }

    init(sections: [Section], profiles: [Profile], activeProfileID: String?) {
        self.sections = sections
        self.profiles = profiles
        self.activeProfileID = activeProfileID
    }

    /// Captures what the sidebar shows now. Placeholder rows are not saved.
    init(sections: [SidebarSection], profiles: [SidebarProfile], activeProfileID: ProfileKey?) {
        self.sections = sections.filter { !$0.isDocSection }.map { section in // document sections come back with the document
            Section(machineID: section.machine?.id.rawValue, machineName: section.machine?.name,
                    machineKind: section.machine.map { Self.kindName($0.kind) }, isCollapsed: section.isCollapsed,
                    nodes: section.nodes.compactMap(Self.node))
        }
        self.profiles = profiles.map { Profile(id: $0.id.rawValue, name: $0.name, color: $0.color?.rawValue, icon: $0.icon) }
        self.activeProfileID = activeProfileID?.rawValue
    }

    /// The saved sections as sidebar sections: every row `.stale`, every
    /// machine header connecting.
    var sidebarSections: [SidebarSection] {
        sections.map { section in
            let nodes = section.nodes.compactMap(Self.sidebarNode)
            guard let id = section.machineID else { return SidebarSection(kind: .pinned, isCollapsed: section.isCollapsed, nodes: nodes) }
            let machine = SidebarMachine(id: MachineID(id), name: section.machineName ?? "", kind: Self.kind(section.machineKind),
                                         status: .connecting)
            return SidebarSection(kind: .machine(machine), isCollapsed: section.isCollapsed, nodes: nodes)
        }
    }

    var sidebarProfiles: [SidebarProfile] {
        profiles.map { SidebarProfile(id: ProfileKey($0.id), name: $0.name, color: $0.color.flatMap(GroupColor.init(rawValue:)), icon: $0.icon) }
    }

    var sidebarActiveProfileID: ProfileKey? { activeProfileID.map(ProfileKey.init) }

    /// Every saved workspace id, in order.
    var workspaceIDs: [String] {
        sections.flatMap(\.nodes).flatMap { node in node.workspace.map { [$0] } ?? node.group?.workspaces ?? [] }.map(\.id)
    }

    private static func node(_ node: SidebarNode) -> Node? {
        switch node {
        case let .workspace(ws):
            guard !ws.rowState.isPending else { return nil }
            return Node(workspace: workspace(ws), group: nil)
        case let .group(group):
            let rows = group.workspaces.filter { !$0.rowState.isPending }.map(workspace)
            return Node(workspace: nil, group: Group(id: group.id.rawValue, name: group.name, color: group.color.rawValue,
                                                     isCollapsed: group.isCollapsed, isPinned: group.isPinned, workspaces: rows))
        case .item:
            return nil // a document item: the document keeps it
        }
    }

    private static func sidebarNode(_ node: Node) -> SidebarNode? {
        if let ws = node.workspace { return .workspace(sidebarWorkspace(ws)) }
        guard let group = node.group else { return nil }
        return .group(SidebarGroup(id: GroupID(group.id), name: group.name, color: GroupColor(rawValue: group.color) ?? .grey,
                                   isCollapsed: group.isCollapsed, isPinned: group.isPinned,
                                   workspaces: group.workspaces.map(sidebarWorkspace)))
    }

    private static func workspace(_ ws: SidebarWorkspace) -> Workspace {
        var icon: String?
        var tint: String?
        switch ws.icon {
        case let .symbol(name, color)?:
            icon = "symbol:" + name
            tint = color?.rawValue
        case let .swatch(color)?: icon = "swatch:" + color.rawValue
        case let .emoji(text, chip)?:
            icon = "emoji:" + text
            tint = chip?.rawValue
        // A favicon is not saved: the live row brings it back.
        case .favicon?, nil: break
        }
        return Workspace(id: ws.id.rawValue, machineID: ws.machineID.rawValue, title: ws.title,
                         kind: ws.kind.rawValue, kindBrand: ws.kindBrand, icon: icon, iconTint: tint)
    }

    private static func sidebarWorkspace(_ ws: Workspace) -> SidebarWorkspace {
        SidebarWorkspace(id: WorkspaceID(ws.id), machineID: MachineID(ws.machineID), title: ws.title,
                         icon: ws.icon.flatMap { icon($0, tint: ws.iconTint) },
                         kind: SidebarWorkspaceKind(rawValue: ws.kind ?? "terminal") ?? .terminal,
                         kindBrand: ws.kindBrand, rowState: .stale)
    }

    private static func icon(_ value: String, tint: String?) -> WorkspaceIcon? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let kind = value[..<colon]
        let rest = String(value[value.index(after: colon)...])
        switch kind {
        case "symbol": return .symbol(rest, tint: tint.flatMap(GroupColor.init(rawValue:)))
        case "swatch": return GroupColor(rawValue: rest).map(WorkspaceIcon.swatch)
        case "emoji": return .emoji(rest, chip: tint.flatMap(GroupColor.init(rawValue:)))
        default: return nil
        }
    }

    private static func kindName(_ kind: SidebarMachine.Kind) -> String {
        switch kind {
        case .local: "local"
        case .cloud: "cloud"
        case .ssh: "ssh"
        case .server: "server"
        }
    }

    private static func kind(_ name: String?) -> SidebarMachine.Kind {
        switch name {
        case "cloud": .cloud
        case "ssh": .ssh
        case "server": .server
        default: .local
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
/// The oracle's `sidebar` facet (schemas/oracle/snapshot-v1.schema.json `sidebar`): what the active
/// window's sidebar shows, read like the saved snapshot above from the one store, `SidebarModel`, through public
/// values only (sections, groups, rows, folds, pins, filter, selection), never from the list's views or row frames.
/// Chromium's tab strip tests read the same way, from the model that owns the strip
/// (chrome/browser/ui/tabs/tab_strip_model.h), not its views. Two inputs are not the store's: edit mode is
/// `SidebarView.isEditingItems` (a public flag, no tree walk), and `widthFraction` divides by the window's width,
/// the frame the `windows` facet reads too.
@MainActor
extension SidebarSnapshot {
    static func oracleFacet(_ services: AppServices) -> OracleFacetSource {
        OracleFacetSource(.sidebar, .mainActor { [weak services] () throws(OracleFacetError) -> OracleValue in
            guard let services else { throw OracleFacetError("the app services are gone") }
            guard let controller = services.windows.active else {
                return .notComparable(reason: "no window shows a sidebar", task: OracleFacet.sidebar.task)
            }
            return oracleValue(
                of: controller.sidebar.model,
                window: ControlWindowInfo.publicID(forKey: controller.state.id),
                editing: controller.sidebar.container.sidebarView.isEditingItems,
                windowWidth: controller.window?.frame.width ?? 0,
                workspaceID: { id in services.workspace(id: id.rawValue)?.resourceID?.rawValue ?? id.rawValue }
            )
        })
    }

    /// `model` in the schema's form. `workspaceID` gives a row's public id (`ws_…`, as `snapshot.get` prints it).
    /// Rows list in model order: each section, then its nodes; a group before its members, which sit one level
    /// deeper; members of a collapsed group or section stay listed, the fold is on their header.
    static func oracleValue(of model: SidebarModel, window: String, editing: Bool, windowWidth: CGFloat,
                            workspaceID: (WorkspaceID) -> String) -> OracleValue {
        let selected: OracleValue = model.activeWorkspaceID.map { OracleValue.string(workspaceID($0)) } ?? .null
        let selection = model.orderedSelection.map { OracleValue.string(workspaceID($0)) }
        let filter: OracleValue = model.filterText.isEmpty ? .null : .string(oracleHash(model.filterText))
        let widthFraction = windowWidth > 0 ? Double(model.displayWidth / windowWidth) : 0
        return [
            "window": .string(window),
            "hidden": .bool(model.isHidden),
            "editing": .bool(editing),
            "widthFraction": .number(widthFraction),
            "selectedWorkspace": selected,
            "selection": .array(selection),
            "filterSha256": filter,
            "rows": .array(oracleRows(model, workspaceID: workspaceID)),
        ]
    }

    /// The filter is typed text: only its hash is recorded (schemas/oracle/README.md, "Private text").
    static func oracleHash(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func oracleRows(_ model: SidebarModel, workspaceID: (WorkspaceID) -> String) -> [OracleValue] {
        let isPinned = model.workspacePin?.isPinned
        func workspaceRow(_ workspace: SidebarWorkspace, group: GroupID?, depth: Int, inPinned: Bool) -> OracleValue {
            let id = workspace.id
            return oracleRow(kind: "workspace", workspace: .string(workspaceID(id)), group: group, label: .string(workspace.title),
                             depth: depth, selected: model.selection.contains(id) || model.activeWorkspaceID == id,
                             collapsed: model.collapsedWorkspaces.contains(id), unread: oracleUnread(workspace.unread),
                             needsYou: workspace.agentChip == .needsYou, pinned: inPinned || isPinned?(id) == true)
        }
        /// A document item's title can be a tab's (private text), so its label is null.
        func itemRow(_ item: SidebarListItem, group: GroupID?, depth: Int) -> OracleValue {
            oracleRow(kind: "item", group: group, depth: depth, selected: model.selectedItem == .topItem(LayoutItemID(item.id)))
        }
        var rows: [OracleValue] = []
        for section in model.sections {
            let inPinned = section.id == .pinned
            rows.append(oracleRow(kind: "section", label: oracleLabel(section), depth: 0, collapsed: oracleCollapsed(section, in: model)))
            for node in section.nodes {
                switch node {
                case .workspace(let workspace):
                    rows.append(workspaceRow(workspace, group: nil, depth: 0, inPinned: inPinned))
                case .group(let group):
                    rows.append(oracleRow(kind: "group", group: group.id, label: .string(group.name), depth: group.depth,
                                          selected: model.selectedItem == .group(group.id), collapsed: group.isCollapsed,
                                          unread: group.unreadTotal, needsYou: group.workspaces.contains { $0.agentChip == .needsYou },
                                          pinned: group.isPinned))
                    for member in group.members {
                        switch member {
                        case .workspace(let workspace):
                            rows.append(workspaceRow(workspace, group: group.id, depth: group.depth + 1, inPinned: inPinned))
                        case .item(let item):
                            rows.append(itemRow(item, group: group.id, depth: group.depth + 1))
                        }
                    }
                case .item(let item):
                    rows.append(itemRow(item, group: nil, depth: 0))
                }
            }
        }
        return rows
    }

    private static func oracleRow(kind: String, workspace: OracleValue = .null, group: GroupID? = nil, label: OracleValue = .null,
                                  depth: Int, selected: Bool = false, collapsed: Bool = false, unread: Int = 0,
                                  needsYou: Bool = false, pinned: Bool = false) -> OracleValue {
        let groupID: OracleValue = group.map { OracleValue.string($0.rawValue) } ?? .null
        return [
            "kind": .string(kind),
            "workspace": workspace,
            "group": groupID,
            "label": label,
            "depth": OracleValue(depth),
            "selected": .bool(selected),
            "collapsed": .bool(collapsed),
            "unread": OracleValue(unread),
            "needsYou": .bool(needsYou),
            "pinned": .bool(pinned),
        ]
    }

    /// The section's kind, not the machine's name (the host's name differs between runs); a custom section's title.
    private static func oracleLabel(_ section: SidebarSection) -> OracleValue {
        switch section.kind {
        case .pinned: return "pinned"
        case .machine(let machine): return .string(kindName(machine.kind))
        case .custom(let custom): return custom.title.map(OracleValue.string) ?? .null
        }
    }

    /// A machine or Pinned section folds in `collapsedSections`; a document section in `collapsedLayoutSections`.
    private static func oracleCollapsed(_ section: SidebarSection, in model: SidebarModel) -> Bool {
        if section.isCollapsed || model.collapsedSections.contains(section.id) { return true }
        guard case .custom(let custom) = section.kind else { return false }
        return model.collapsedLayoutSections.contains(LayoutSectionID(custom.id))
    }

    /// A dot is one unread, as a group header counts it (`SidebarGroup.unreadTotal`).
    private static func oracleUnread(_ state: UnreadState) -> Int {
        switch state {
        case .none: 0
        case .dot: 1
        case .count(let count): max(0, count)
        }
    }
}
#endif
