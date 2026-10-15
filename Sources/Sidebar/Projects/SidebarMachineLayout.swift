import AppKit
import CmuxWorkspaces
import SwiftUI

// Codex and Machine rail: the glass list (the native table with its rows,
// headers and drag) arranged by machine, from design/sidebar-variations.html.
//
// Codex: Pinned, then Cloud with a folder per Cloud machine, then Local and any
// other Macs. The app's own groups are flattened into those sections.
// Machine rail: a column of machines beside the list; the list shows the
// chosen machine's workspaces, the app's groups kept.
//
// Sections are header-only groups that exist only in the sidebar. The real
// workspace order and groups change only when a drop asks for it, translated
// from the shown list. Shared by the app and labs/SidebarLab.

/// What the machine layouts remember: the rail's machine, folded sections, and
/// where sections and Cloud machines were dragged.
@MainActor
final class SidebarMachineLayoutState: ObservableObject {
    static let shared = SidebarMachineLayoutState()
    private static let key = "sidebarMachineLayoutState"

    /// The machine the rail shows.
    @Published var railMachine = SidebarProjectsRow.Place.local
    /// Folded sections and machines, by title.
    @Published var collapsed: Set<String> = [] { didSet { save() } }
    /// Section order the user dragged into; empty until a header moves.
    @Published var sectionOrder: [String] = [] { didSet { save() } }
    /// Cloud machines dragged under Pinned.
    @Published var pinnedMachines: Set<String> = [] { didSet { save() } }
    /// The order Cloud machines were dragged into.
    @Published var machineOrder: [String] = [] { didSet { save() } }

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
        collapsed = Set(saved["collapsed"] ?? [])
        sectionOrder = saved["sectionOrder"] ?? []
        pinnedMachines = Set(saved["pinnedMachines"] ?? [])
        machineOrder = saved["machineOrder"] ?? []
    }

    func toggle(_ title: String) {
        if collapsed.contains(title) { collapsed.remove(title) } else { collapsed.insert(title) }
    }

    private func save() {
        UserDefaults.standard.set([
            "collapsed": collapsed.sorted(),
            "sectionOrder": sectionOrder,
            "pinnedMachines": pinnedMachines.sorted(),
            "machineOrder": machineOrder,
        ], forKey: Self.key)
    }
}

enum SidebarMachineLayout {
    static let pinnedTitle = "Pinned"
    static let cloudTitle = "Cloud"
    static let localTitle = "Local"

    /// One workspace as the layouts see it.
    struct Item {
        let id: UUID
        let isPinned: Bool
        let place: SidebarProjectsRow.Place
        let groupId: UUID?
    }

    /// A header-only section.
    struct Section: Equatable {
        let title: String
        /// A Cloud machine under Cloud (or Pinned): one step in.
        let isNested: Bool
        /// Where its rows run; nil for Pinned and Cloud.
        let place: SidebarProjectsRow.Place?
    }

    /// The list to show: which workspaces in which order, the groups to draw
    /// them under, and the sections among those groups.
    struct Pass {
        var ids: [UUID]
        var groups: [WorkspaceGroup]
        /// Codex: each workspace's section. Nil keeps the app's own membership.
        var membership: [UUID: UUID?]?
        var sections: [UUID: Section]
        /// Rows that sit under their own machine, so their machine badge can
        /// say what they hold instead of repeating where they are.
        var underMachine: Set<UUID>
    }

    static func displayName(_ title: String) -> String {
        switch title {
        case pinnedTitle: return String(localized: "sidebar.machineLayout.pinned", defaultValue: "Pinned")
        case cloudTitle: return String(localized: "sidebar.machineLayout.cloud", defaultValue: "Cloud")
        case localTitle: return String(localized: "sidebar.machineLayout.local", defaultValue: "Local")
        default: return title
        }
    }

    static func title(of place: SidebarProjectsRow.Place) -> String {
        switch place {
        case .local: return localTitle
        case .cloud(let name), .device(let name): return name
        }
    }

    /// A stable id for a section, from its title.
    static func sectionId(_ title: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in ("cmux.section." + title).utf8.enumerated() { bytes[index % 16] &+= byte &+ UInt8(index % 251) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: Codex

    /// Pinned, then Cloud with its machines, then Local and other Macs. Sections
    /// keep the order they were dragged into; folded Pinned or Cloud hides the
    /// machines under it.
    @MainActor
    static func codex(_ items: [Item], state: SidebarMachineLayoutState) -> Pass {
        let cloud = Set(items.compactMap { item -> String? in
            if case .cloud(let name) = item.place { return name } else { return nil }
        })
        var order: [String] = []
        var bySection: [String: [UUID]] = [:]
        for item in items {
            let section = item.isPinned ? pinnedTitle : title(of: item.place)
            if bySection[section] == nil { order.append(section) }
            bySection[section, default: []].append(item.id)
        }
        let rank: (String) -> Int = { $0 == pinnedTitle ? 0 : $0 == localTitle ? 2 : 1 }
        order = order.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        let placed = state.machineOrder
        let machines = order.filter(cloud.contains).enumerated().sorted {
            (placed.firstIndex(of: $0.element) ?? placed.count, $0.offset) < (placed.firstIndex(of: $1.element) ?? placed.count, $1.offset)
        }.map(\.element)
        order.removeAll(where: cloud.contains)
        // Pinned and Cloud always show, so something can be dropped on them.
        if !order.contains(pinnedTitle) { order.insert(pinnedTitle, at: 0) }
        if !order.contains(cloudTitle), !cloud.isEmpty {
            order.insert(cloudTitle, at: (order.firstIndex(of: pinnedTitle) ?? -1) + 1)
        }
        if !state.sectionOrder.isEmpty {
            let sectionOrder = state.sectionOrder
            order = order.enumerated().sorted {
                (sectionOrder.firstIndex(of: $0.element) ?? sectionOrder.count, $0.offset)
                    < (sectionOrder.firstIndex(of: $1.element) ?? sectionOrder.count, $1.offset)
            }.map(\.element)
        }
        let open: (String) -> Bool = { !state.collapsed.contains($0) }
        order = order.flatMap { section -> [String] in
            switch section {
            case pinnedTitle where open(section): return [section] + machines.filter(state.pinnedMachines.contains)
            case cloudTitle where open(section): return [section] + machines.filter { !state.pinnedMachines.contains($0) }
            default: return [section]
            }
        }
        var pass = Pass(ids: [], groups: [], membership: [:], sections: [:], underMachine: [])
        for section in order {
            let id = sectionId(section)
            let isMachine = cloud.contains(section)
            let place: SidebarProjectsRow.Place?
            switch section {
            case pinnedTitle, cloudTitle: place = nil
            case localTitle: place = .local
            default: place = isMachine ? .cloud(section) : .device(section)
            }
            pass.sections[id] = Section(title: section, isNested: isMachine, place: place)
            // Pinned, Cloud and Local are text headers; only machines carry a glyph.
            var icon: String?
            if isMachine {
                icon = "cloud"
            } else if case .some(.device) = place {
                icon = "desktopcomputer"
            }
            pass.groups.append(WorkspaceGroup(
                id: id, name: displayName(section), isCollapsed: state.collapsed.contains(section), isPinned: false,
                anchor: .empty(id), customColor: nil, iconSymbol: icon, anchorWorkspaceProvenance: .user
            ))
            for workspaceId in bySection[section] ?? [] {
                pass.ids.append(workspaceId)
                pass.membership?[workspaceId] = id
                if let place, place != .local { pass.underMachine.insert(workspaceId) }
            }
        }
        return pass
    }

    /// Where a dropped row lands in the full order, and whether it ends up pinned.
    /// Nil when the drop can't be honored: a workspace can't move to another
    /// machine by dragging, and Cloud holds machines, not rows.
    static func codexDrop(
        dragged: UUID,
        moving: [UUID],
        targetIndex: Int,
        explicitSection: UUID?,
        pass: Pass,
        items: [Item],
        realOrder: [UUID]
    ) -> (order: [UUID], pinned: Bool)? {
        let movingSet = Set(moving)
        let membership = pass.membership ?? [:]
        // The target gap is counted without the dragged row.
        let rest = pass.ids.filter { $0 != dragged }
        let neighbor = targetIndex < rest.count
            ? rest[targetIndex...].first { !movingSet.contains($0) }
            : nil
        let fallbackSection = (neighbor ?? rest.last).flatMap { membership[$0] ?? nil }
        guard let sectionId = explicitSection.flatMap({ pass.sections[$0] != nil ? $0 : nil }) ?? fallbackSection,
              let section = pass.sections[sectionId] else { return nil }
        let pinned: Bool
        if section.title == pinnedTitle {
            pinned = true
        } else if let place = section.place {
            let places = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.place) })
            guard moving.allSatisfy({ places[$0] == place }) else { return nil }
            pinned = false
        } else {
            return nil
        }
        var order = realOrder.filter { !movingSet.contains($0) }
        let sectionMembers = Set(pass.ids.filter { membership[$0] == sectionId && !movingSet.contains($0) })
        let insertAt: Int
        if let neighbor, sectionMembers.contains(neighbor), let index = order.firstIndex(of: neighbor) {
            insertAt = index
        } else if let last = order.lastIndex(where: sectionMembers.contains) {
            insertAt = last + 1
        } else {
            // An empty section: pins go on top, anything else after its machine's last workspace.
            insertAt = pinned ? 0 : order.count
        }
        let ordered = realOrder.filter(movingSet.contains)
        order.insert(contentsOf: ordered, at: min(insertAt, order.count))
        return (order, pinned)
    }

    /// A section header dropped at `index` among `shown` (headers in display
    /// order). A Cloud machine belongs to whichever of Pinned or Cloud sits
    /// above it; any other section just takes the new order.
    @MainActor
    static func moveSection(_ title: String, toIndex index: Int, among shown: [String], cloud: Set<String>, state: SidebarMachineLayoutState) {
        var after = shown.filter { $0 != title }
        after.insert(title, at: max(0, min(index, after.count)))
        guard after != shown else { return }
        if cloud.contains(title) {
            let above = after.prefix(while: { $0 != title }).last { !cloud.contains($0) }
            if above == pinnedTitle { state.pinnedMachines.insert(title) }
            if above == cloudTitle { state.pinnedMachines.remove(title) }
            let machines = after.filter(cloud.contains)
            state.machineOrder = machines + state.machineOrder.filter { !machines.contains($0) }
        } else {
            state.sectionOrder = after.filter { !cloud.contains($0) }
        }
    }

    // MARK: Machine rail

    /// The chosen machine's workspaces, plus the header workspace of any group
    /// with one of them in it, so the group's header still draws.
    static func rail(_ items: [Item], groups: [WorkspaceGroup], machine: SidebarProjectsRow.Place) -> Pass {
        let shown = Set(items.filter { $0.place == machine }.map(\.id))
        var visible = shown
        let anchors = Dictionary(groups.compactMap { group in group.liveAnchorWorkspaceId.map { (group.id, $0) } }, uniquingKeysWith: { first, _ in first })
        for item in items where shown.contains(item.id) {
            if let groupId = item.groupId, let anchor = anchors[groupId] { visible.insert(anchor) }
        }
        return Pass(
            ids: items.map(\.id).filter(visible.contains),
            groups: groups.filter { $0.liveAnchorWorkspaceId.map(visible.contains) ?? false },
            membership: nil,
            sections: [:],
            underMachine: machine == .local ? [] : shown
        )
    }

    /// A drop gap in the shown list as the same gap in the full one: before the
    /// item that follows it, or right after the last shown item. Both lists are
    /// counted without the dragged item, as the drop planner counts them.
    static func fullIndex(gap: Int, dragged: UUID, shown: [UUID], full: [UUID]) -> Int {
        let shownRest = shown.filter { $0 != dragged }
        let fullRest = full.filter { $0 != dragged }
        if gap < shownRest.count, let index = fullRest.firstIndex(of: shownRest[gap]) { return index }
        if let last = shownRest.last, let index = fullRest.firstIndex(of: last) { return index + 1 }
        return fullRest.count
    }

    /// Top-level rows: a group's run counts once (as its id), any other workspace as itself.
    static func topLevelKeys(_ ids: [UUID], groupOf: (UUID) -> UUID?) -> [UUID] {
        var keys: [UUID] = []
        for id in ids {
            let key = groupOf(id) ?? id
            if keys.last != key { keys.append(key) }
        }
        return keys
    }
}

// MARK: - Chrome around the list

/// Codex: New workspace and Search above the sections.
struct SidebarCodexHeader: View {
    static let height: CGFloat = 62
    let newWorkspace: () -> Void
    let search: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            NavRow(symbol: "square.and.pencil", title: String(localized: "sidebar.projects.newWorkspace", defaultValue: "New workspace"), action: newWorkspace)
            NavRow(symbol: "magnifyingglass", title: String(localized: "sidebar.projects.search", defaultValue: "Search"), action: search)
        }
        .padding(.horizontal, 6)
    }

    private struct NavRow: View {
        let symbol: String
        let title: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
                Text(title).font(.system(size: 13))
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
        }
    }
}

/// Machine rail: one button per machine, an unread dot on the others, + for a new Cloud machine.
struct SidebarMachineRail: View {
    static let width: CGFloat = 44
    struct Machine: Hashable {
        let place: SidebarProjectsRow.Place
        let unread: Int
    }
    let machines: [Machine]
    let selected: SidebarProjectsRow.Place
    let select: (SidebarProjectsRow.Place) -> Void
    let newMachine: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(machines, id: \.place) { machine in
                RailButton(
                    symbol: machine.place.symbol,
                    help: machine.place == .local ? SidebarMachineLayout.displayName(SidebarMachineLayout.localTitle) : machine.place.name,
                    isSelected: machine.place == selected,
                    showsUnread: machine.place != selected && machine.unread > 0
                ) { select(machine.place) }
            }
            Spacer(minLength: 0)
            RailButton(symbol: "plus", help: String(localized: "sidebar.projects.newCloudMachine", defaultValue: "New Cloud Machine…"),
                       isSelected: false, showsUnread: false, action: newMachine)
        }
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(width: Self.width)
    }

    /// The rail's hairline: it starts level with the first button, below the
    /// titlebar controls, and fades out at both ends.
    static var divider: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, Color.primary.opacity(0.1)], startPoint: .top, endPoint: .bottom).frame(height: 24)
            Color.primary.opacity(0.1)
            LinearGradient(colors: [Color.primary.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom).frame(height: 40)
        }
        .frame(width: 0.5)
    }

    private struct RailButton: View {
        let symbol: String
        let help: String
        let isSelected: Bool
        let showsUnread: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(isSelected ? 0.13 : hovering ? 0.06 : 0))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(isSelected ? 0.2 : 0), lineWidth: 1))
                    )
                    .overlay(alignment: .topTrailing) {
                        if showsUnread { Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: -3, y: 3) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            // The machine's name in a pill beside the rail, in place of the system tooltip.
            .overlay(alignment: .leading) {
                if hovering {
                    // Long generated names cut in the middle, so both ends stay readable.
                    Text(help)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(width: Self.tipTextWidth(help))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.2)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .fixedSize()
                        .offset(x: 30 + 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .zIndex(hovering ? 1 : 0)
        }

        /// The name's width, capped so the pill stays inside a narrow sidebar.
        private static func tipTextWidth(_ text: String) -> CGFloat {
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            return min(ceil(width) + 1, 170)
        }
    }
}

/// Machine rail: the chosen machine's name and what it is over its list.
struct SidebarRailHeader: View {
    static let height: CGFloat = 40
    let machine: SidebarProjectsRow.Place
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(machine == .local ? SidebarMachineLayout.displayName(SidebarMachineLayout.localTitle) : machine.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private var detail: String {
        let workspaces = count == 1
            ? String(localized: "sidebar.layouts.machine.oneWorkspace", defaultValue: "1 workspace")
            : String(localized: "sidebar.layouts.machine.workspaces", defaultValue: "\(count) workspaces")
        let kind: String
        switch machine {
        case .local: kind = String(localized: "sidebar.machineLayout.thisMac", defaultValue: "This Mac")
        case .cloud: kind = String(localized: "sidebar.layouts.machine.cloud", defaultValue: "Cloud machine")
        case .device: kind = String(localized: "sidebar.machineLayout.otherMac", defaultValue: "Other Mac")
        }
        return kind + " · " + workspaces
    }
}

/// The strips around the list: Codex's rows above it, or the rail beside it
/// with the machine's name above. The list fills the rest.
struct SidebarMachineLayoutChrome<Content: View>: View {
    let layout: String
    let machines: [SidebarMachineRail.Machine]
    let count: Int
    let topInset: CGFloat
    /// The list's own titlebar inset, pulled up under a header strip.
    let listTopInset: CGFloat
    /// Room kept under the rail for the app's footer.
    var bottomInset: CGFloat = 0
    var newWorkspace: () -> Void = {}
    var search: () -> Void = {}
    var newMachine: () -> Void = {}
    @ObservedObject var state = SidebarMachineLayoutState.shared
    @ViewBuilder let list: () -> Content

    var body: some View {
        if layout == "rail" {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: topInset)
                    SidebarMachineRail(machines: machines, selected: state.railMachine, select: { place in
                        withAnimation(.snappy(duration: 0.2)) { state.railMachine = place }
                    }, newMachine: newMachine)
                }
                .padding(.bottom, bottomInset)
                .frame(width: SidebarMachineRail.width)
                .zIndex(1)
                SidebarMachineRail.divider
                    .padding(.top, topInset + 2)
                    .padding(.bottom, 12 + bottomInset)
                VStack(spacing: 0) {
                    Color.clear.frame(height: topInset)
                    SidebarRailHeader(machine: state.railMachine, count: count).frame(height: SidebarRailHeader.height)
                    list().padding(.top, -listTopInset)
                }
            }
        } else {
            VStack(spacing: 0) {
                Color.clear.frame(height: topInset)
                SidebarCodexHeader(newWorkspace: newWorkspace, search: search).frame(height: SidebarCodexHeader.height)
                list().padding(.top, -listTopInset)
            }
        }
    }
}
