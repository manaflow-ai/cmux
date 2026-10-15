import AppKit
import SwiftUI

// The Projects sidebar: workspace groups shown as projects, each project's
// workspaces aligned to its name (the status mark hangs in the column of the
// project's icon, so there is one level and no staircase), and Cloud as a mark
// on the row instead of a folder level. Every choice is a SidebarProjectsStyle
// setting; templates are presets, edited live in the Customize popover.
// The same files run in labs/SidebarLab, fed from the lab's fake data.

/// One workspace, as the Projects sidebar shows it.
struct SidebarProjectsRow: Identifiable, Equatable {
    enum Status: Equatable { case idle, working, needsInput, failed, done }

    /// Where the workspace runs.
    enum Place: Hashable {
        case local
        case cloud(String)
        case device(String)

        var name: String {
            switch self {
            case .local: return String(localized: "sidebar.projects.thisMac", defaultValue: "This Mac")
            case .cloud(let name), .device(let name): return name
            }
        }

        var symbol: String {
            switch self {
            case .local: return "laptopcomputer"
            case .cloud: return "cloud"
            case .device: return "desktopcomputer"
            }
        }

        /// Generated three-word machine names shorten to their last word.
        var shortName: String {
            let parts = name.split(separator: "-")
            return parts.count >= 3 ? String(parts[parts.count - 1]) : name
        }
    }

    let id: UUID
    var title: String
    var groupId: UUID?
    var isPinned = false
    var status = Status.idle
    var unread = 0
    /// Agent kinds running in the workspace ("claude", "codex", "opencode"), first is the main one.
    var agents: [String] = []
    var place = Place.local
    var branch: String?
    var directory = ""
    var message: String?
    var age: String?
    var added: Int?
    var removed: Int?
    /// Ports the workspace is serving (Machine tabs lists them).
    var ports: [Int] = []
    /// The workspace shows a display (Machine tabs lists it).
    var isDisplay = false
}

struct SidebarProjectsGroup: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isPinned = false
    /// Hex, like WorkspaceGroup.customColor.
    var color: String?
    /// The workspace the project row stands for (WorkspaceGroup's live anchor):
    /// clicking the row opens it, like the native group header.
    var anchorId: UUID?
}

/// What the sidebar asks its host to do.
struct SidebarProjectsActions {
    var select: (UUID) -> Void = { _ in }
    /// A new workspace in a project (nil: none) on a machine (nil: This Mac).
    var newWorkspace: (UUID?, SidebarProjectsRow.Place?) -> Void = { _, _ in }
    var newCloudMachine: (UUID?) -> Void = { _ in }
    /// The workspaces in the first list take the order of the second.
    var reorderRows: ([UUID], [UUID]) -> Void = { _, _ in }
    var reorderGroups: ([UUID]) -> Void = { _ in }
    var togglePin: (UUID) -> Void = { _ in }
    var toggleRead: (UUID) -> Void = { _ in }
    /// A new project holding that workspace, or a fresh one when nil.
    var newProject: (UUID?) -> Void = { _ in }
    var moveToProject: (UUID, UUID) -> Void = { _, _ in }
    var removeFromProject: (UUID) -> Void = { _ in }
    var close: (UUID) -> Void = { _ in }
    var toggleProjectPin: (UUID) -> Void = { _ in }
    var markProjectRead: (UUID) -> Void = { _ in }
    var ungroupProject: (UUID) -> Void = { _ in }
    var deleteProject: (UUID) -> Void = { _ in }
    var search: () -> Void = {}
    /// Opens the Cloud machines panel, or closes it when it is already open.
    var showCloudMachines: () -> Void = {}
    var openSettings: () -> Void = {}
}

struct SidebarProjectsView: View {
    /// Every workspace, anchors included (a project's anchor shows as its row).
    let rows: [SidebarProjectsRow]
    /// Projects in display order.
    let groups: [SidebarProjectsGroup]
    /// Cloud machines and other devices the user has, for "New Workspace on…".
    var machines: [SidebarProjectsRow.Place] = []
    let selectedId: UUID?
    var accountName = ""
    /// Space left for the titlebar controls above the first row.
    var topInset: CGFloat = 0
    /// Space kept clear under the list (the app's own footer sits there).
    var bottomInset: CGFloat = 0
    /// The app draws its own footer; the lab uses this one.
    var showsOwnFooter = true
    var actions = SidebarProjectsActions()
    var agentIcon: (String) -> NSImage? = { _ in nil }

    @ObservedObject private var store = SidebarProjectsStyleStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var collapsed: Set<String> = []
    @State private var machineFilter: SidebarProjectsRow.Place?
    @State private var newHover = false
    @State private var menu: ProjectsMenuRequest?
    @State private var frame: CGRect = .zero

    private var style: SidebarProjectsStyle { store.style }
    private var palette: SidebarProjectsPalette { SidebarProjectsPalette(dark: colorScheme == .dark, accent: style.accent) }
    private var metrics: Metrics { Metrics(style: style) }

    var body: some View {
        let palette = palette
        VStack(spacing: 0) {
            Color.clear.frame(height: topInset)
            top
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(style.sections) { section in
                        sectionView(section.id, visibility: section.visibility)
                    }
                }
                .padding(.horizontal, metrics.margin)
                .padding(.bottom, 10 + bottomInset)
            }
            // Right-click on empty space: the way back to Customize when the account bar is hidden.
            .background { Color.clear.modifier(ProjectsRightClick { point in menu = ProjectsMenuRequest(point: point, entries: emptyAreaMenu) }) }
            if style.footer, showsOwnFooter { footer }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(palette.label)
        .background(style.backdrop == .solid ? palette.bg : Color.clear)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        .overlay {
            if let menu { ProjectsMenuOverlay(request: menu, container: frame, palette: palette) { self.menu = nil }.id(menu.id) }
        }
        .popover(isPresented: $store.isCustomizing, arrowEdge: .trailing) {
            SidebarProjectsCustomizePanel(store: store)
        }
        .animation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: rows.map(\.id))
        .animation(.snappy(duration: 0.2), value: style)
    }

    // MARK: Data

    /// Workspaces that get a row: a project's anchor is the project row instead.
    private var visibleRows: [SidebarProjectsRow] {
        let anchors = style.groupBy == .project ? Set(groups.compactMap(\.anchorId)) : []
        return rows.filter { !anchors.contains($0.id) && (machineFilter == nil || $0.place == machineFilter) }
    }

    private func anchorRow(_ group: SidebarProjectsGroup) -> SidebarProjectsRow? {
        group.anchorId.flatMap { id in rows.first { $0.id == id } }
    }

    /// Pins lift a workspace or project into the Pinned section only while that
    /// section shows. With it hidden they stay in place, so nothing drops out of view.
    private var pinsFloat: Bool { style.visibility(.pinned) != .hidden }

    private func floatsToPinned(_ row: SidebarProjectsRow) -> Bool { pinsFloat && row.isPinned }

    private var pinnedGroupIds: Set<UUID> {
        style.groupBy == .project && pinsFloat ? Set(groups.filter(\.isPinned).map(\.id)) : []
    }

    private func inPinnedProject(_ row: SidebarProjectsRow) -> Bool {
        row.groupId.map(pinnedGroupIds.contains) ?? false
    }

    private var knownGroupIds: Set<UUID> { Set(groups.map(\.id)) }

    /// A project's rows. A workspace pinned on its own shows under Pinned instead,
    /// unless the whole project is pinned.
    private func members(of group: SidebarProjectsGroup) -> [SidebarProjectsRow] {
        let projectPinned = pinnedGroupIds.contains(group.id)
        return visibleRows.filter { $0.groupId == group.id && (!floatsToPinned($0) || projectPinned) }
    }

    /// A project shows unless the machine filter leaves it nothing. Its own workspace
    /// counts, so a project that is only its header still shows.
    private func matchesFilter(_ project: SidebarProjectsGroup) -> Bool {
        guard let machineFilter else { return true }
        return anchorRow(project)?.place == machineFilter || !members(of: project).isEmpty
    }

    /// Machines in order: This Mac, then Cloud machines, then other devices.
    private var places: [SidebarProjectsRow.Place] {
        var seen: [SidebarProjectsRow.Place] = [.local]
        for place in machines + rows.map(\.place) where !seen.contains(place) { seen.append(place) }
        let rank: (SidebarProjectsRow.Place) -> Int = { place in
            switch place {
            case .local: return 0
            case .cloud: return 1
            case .device: return 2
            }
        }
        return seen.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    // MARK: Top and bottom

    @ViewBuilder private var top: some View {
        let palette = palette
        switch style.newButton {
        case .button:
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").font(.system(size: 12))
                Text(String(localized: "sidebar.projects.newWorkspace", defaultValue: "New workspace")).font(.system(size: metrics.nav))
                Spacer()
                Text(verbatim: "⌘N").font(.system(size: 10.5)).foregroundStyle(palette.label3)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(palette.wash(newHover ? 0.11 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.wash(newHover ? 0.15 : 0.1), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { newHover = hovering } }
            .onTapGesture { actions.newWorkspace(nil, nil) }
            .padding(.horizontal, 10).padding(.bottom, 6)
        case .row:
            nav("square.and.pencil", String(localized: "sidebar.projects.newWorkspace", defaultValue: "New workspace")) { actions.newWorkspace(nil, nil) }
        case .hidden:
            EmptyView()
        }
        if style.search {
            nav("magnifyingglass", String(localized: "sidebar.projects.search", defaultValue: "Search"), action: actions.search)
        }
        if style.cloudNav {
            let count = places.filter { if case .cloud = $0 { return true } else { return false } }.count
            nav("cloud", String(localized: "sidebar.projects.cloudMachines", defaultValue: "Cloud machines"), trailing: count > 0 ? "\(count)" : nil, action: actions.showCloudMachines)
        }
        if let machineFilter {
            HStack(spacing: 6) {
                Image(systemName: machineFilter.symbol).font(.system(size: 10))
                Text(machineFilter.name).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5)).foregroundStyle(palette.accent)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(palette.accent.opacity(0.14)))
            .contentShape(Capsule())
            .onTapGesture { self.machineFilter = nil }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, 6)
        }
    }

    private var footer: some View {
        let palette = palette
        return VStack(spacing: 0) {
            Rectangle().fill(palette.sep).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.system(size: 14))
                Text(accountName).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                ProjectsIconButton(symbol: "slider.horizontal.3", palette: palette) { store.isCustomizing.toggle() }
                    .help(String(localized: "sidebar.projects.customize", defaultValue: "Customize Sidebar"))
                ProjectsIconButton(symbol: "gearshape", palette: palette, action: actions.openSettings)
            }
            .foregroundStyle(palette.label2).padding(.leading, 20).padding(.trailing, 14).padding(.vertical, 8)
        }
    }

    private func nav(_ symbol: String, _ title: String, trailing: String? = nil, action: @escaping () -> Void) -> some View {
        let palette = palette
        return HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 16)
            Text(title).font(.system(size: metrics.nav))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(palette.label3) }
        }
        .foregroundStyle(palette.label2).padding(.horizontal, 10).frame(height: 28)
        .modifier(ProjectsRowChrome(selected: false, radius: 7, style: .rounded, palette: palette, action: action))
        .padding(.horizontal, 10)
    }

    // MARK: Sections

    @ViewBuilder private func sectionView(_ section: SidebarProjectsStyle.Section, visibility: SidebarProjectsStyle.Visibility) -> some View {
        if visibility != .hidden {
            switch section {
            case .pinned: pinnedSection(always: visibility == .always)
            case .groups: groupsSection(always: visibility == .always)
            case .loose: looseSection(always: visibility == .always)
            case .machines: machinesSection
            }
        }
    }

    @ViewBuilder private func pinnedSection(always: Bool) -> some View {
        let pinnedRows = visibleRows.filter { $0.isPinned && !inPinnedProject($0) }
        let pinnedProjects = groups.filter { pinnedGroupIds.contains($0.id) && matchesFilter($0) }
        if always || !pinnedRows.isEmpty || !pinnedProjects.isEmpty {
            header(String(localized: "sidebar.projects.pinned", defaultValue: "Pinned"))
            if pinnedRows.isEmpty, pinnedProjects.isEmpty {
                Text(String(localized: "sidebar.projects.pinnedEmpty", defaultValue: "Pin a workspace or project to keep it here"))
                    .font(.system(size: metrics.detail)).foregroundStyle(palette.label3)
                    .padding(.horizontal, metrics.pad).padding(.vertical, 4)
            }
            if style.pinned == .tiles, !pinnedRows.isEmpty {
                tiles(pinnedRows)
            } else {
                column(pinnedRows, pinnedSection: true)
            }
            projectStack(pinnedProjects)
        }
    }

    @ViewBuilder private func groupsSection(always: Bool) -> some View {
        let unpinned = visibleRows.filter { !floatsToPinned($0) }
        switch style.groupBy {
        case .project:
            let projects = groups.filter { !pinnedGroupIds.contains($0.id) && matchesFilter($0) }
            if always || !projects.isEmpty {
                header(String(localized: "sidebar.projects.projects", defaultValue: "Projects"), symbol: "folder.badge.plus") { actions.newProject(nil) }
                projectStack(projects)
            }
        case .machine:
            let rows = unpinned
            ForEach(places, id: \.self) { place in
                let here = rows.filter { $0.place == place }
                if !here.isEmpty || place == .local {
                    machineBlock(place, rows: here)
                }
            }
        case .status:
            let rows = unpinned
            statusBlock("needs", String(localized: "sidebar.projects.needsYou", defaultValue: "Needs you"), rows.filter { $0.status == .needsInput || $0.status == .failed })
            statusBlock("working", String(localized: "sidebar.projects.working", defaultValue: "Working"), rows.filter { $0.status == .working })
            statusBlock("unread", String(localized: "sidebar.projects.unread", defaultValue: "Unread"), rows.filter { $0.status == .done || ($0.status == .idle && $0.unread > 0) })
            statusBlock("quiet", String(localized: "sidebar.projects.quiet", defaultValue: "Quiet"), rows.filter { $0.status == .idle && $0.unread == 0 })
        case .none:
            let rows = unpinned
            if always || !rows.isEmpty {
                header(String(localized: "sidebar.projects.workspaces", defaultValue: "Workspaces"), symbol: "plus") { actions.newWorkspace(nil, machineFilter) }
                column(rows)
            }
        }
    }

    @ViewBuilder private func looseSection(always: Bool) -> some View {
        // Only grouping by project leaves workspaces outside every group.
        if style.groupBy == .project {
            let loose = visibleRows.filter { row in !floatsToPinned(row) && (row.groupId.map { !knownGroupIds.contains($0) } ?? true) }
            if always || !loose.isEmpty {
                header(String(localized: "sidebar.projects.workspaces", defaultValue: "Workspaces"), symbol: "plus") { actions.newWorkspace(nil, machineFilter) }
                column(loose)
            }
        }
    }

    @ViewBuilder private var machinesSection: some View {
        let palette = palette
        header(String(localized: "sidebar.projects.machines", defaultValue: "Machines"), symbol: "plus") { actions.newCloudMachine(nil) }
        ForEach(places, id: \.self) { place in
            let count = rows.filter { $0.place == place }.count
            let on = machineFilter == place
            HStack(spacing: 9) {
                Image(systemName: place.symbol).font(.system(size: 11)).frame(width: 18)
                Text(place.name).font(.system(size: metrics.title)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: metrics.detail)).foregroundStyle(palette.label3)
            }
            .foregroundStyle(on ? palette.label : palette.label2)
            .padding(.horizontal, metrics.pad).frame(height: metrics.rowHeight)
            .modifier(ProjectsRowChrome(selected: on, radius: metrics.radius, style: style.rows, palette: palette) {
                withAnimation(.snappy(duration: 0.2)) { machineFilter = on ? nil : place }
            })
        }
    }

    private func header(_ title: String, count: Int? = nil, symbol: String? = nil, action: @escaping () -> Void = {}) -> some View {
        let palette = palette
        let caps = style.headers == .caps
        return HStack(spacing: 6) {
            if caps {
                Text(title.uppercased()).font(.system(size: metrics.header, weight: .semibold)).kerning(1)
            } else {
                Text(title).font(.system(size: metrics.header + 2, weight: .medium))
            }
            if let count { Text("\(count)").font(.system(size: metrics.header + (caps ? 0.5 : 2))).opacity(0.75) }
            Spacer()
            if let symbol { ProjectsIconButton(symbol: symbol, palette: palette, action: action) }
        }
        .foregroundStyle(palette.label3)
        .padding(.leading, metrics.pad).padding(.trailing, metrics.pad - 6)
        .padding(.top, caps ? 14 : 12).padding(.bottom, caps ? 4 : 3)
    }

    /// Pinned workspaces as favorites: a grid of tiles, icon over name, status on the corner.
    private func tiles(_ rows: [SidebarProjectsRow]) -> some View {
        let palette = palette
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(rows) { row in
                let selected = selectedId == row.id
                VStack(spacing: 4) {
                    Group {
                        if let agent = row.agents.first {
                            agentImage(agent, size: 16)
                        } else {
                            Text(String(row.title.prefix(1)).uppercased()).font(.system(size: 12, weight: .semibold))
                                .frame(width: 18, height: 18)
                        }
                    }
                    .frame(height: 18)
                    Text(row.title).font(.system(size: metrics.detail - 0.5)).lineLimit(1)
                        .foregroundStyle(selected ? palette.label : palette.label2)
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.wash(selected ? 0.12 : 0.055)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.wash(selected ? 0.16 : 0.04), lineWidth: 1))
                .overlay(alignment: .topTrailing) { if let mark = mark(row) { mark.scaleEffect(0.85).padding(4) } }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { actions.select(row.id) }
                .modifier(ProjectsRightClick { point in menu = ProjectsMenuRequest(point: point, entries: workspaceMenu(row)) })
                .help(row.title)
            }
        }
        .padding(.horizontal, metrics.margin == 0 ? 12 : 2).padding(.vertical, 2)
    }

    // MARK: Blocks

    private func projectStack(_ projects: [SidebarProjectsGroup]) -> some View {
        ProjectsBlockReorderStack(ids: projects.map(\.id), spacing: metrics.blockGap, palette: palette, onCommit: actions.reorderGroups) { id in
            if let project = projects.first(where: { $0.id == id }) {
                let key = project.id.uuidString
                let members = members(of: project)
                let anchor = anchorRow(project)
                let folded = collapsed.contains(key)
                VStack(alignment: .leading, spacing: 0) {
                    BlockHeader(
                        icon: AnyView(projectIcon(project)),
                        title: project.name,
                        collapsed: folded,
                        // Open: the project's own workspace's mark. Folded: the most urgent of all.
                        rollup: folded ? rollup(members + (anchor.map { [$0] } ?? [])) : anchor.flatMap { mark($0) },
                        // Its own workspace is open, or the open one is folded away inside it.
                        selected: anchor?.id == selectedId || (folded && members.contains { $0.id == selectedId }),
                        metrics: metrics, palette: palette, style: style.rows,
                        select: anchor.map { anchor in { actions.select(anchor.id) } },
                        toggle: { toggle(key) },
                        add: { point in
                            menu = ProjectsMenuRequest(point: point, entries: whereMenu(project: project.id))
                        }
                    )
                    .modifier(ProjectsRightClick { point in menu = ProjectsMenuRequest(point: point, entries: projectMenu(project, members: members)) })
                    if !collapsed.contains(key) { column(members, member: true) }
                }
            }
        }
    }

    private func machineBlock(_ place: SidebarProjectsRow.Place, rows: [SidebarProjectsRow]) -> some View {
        let key = "machine:" + place.name
        return VStack(alignment: .leading, spacing: 0) {
            BlockHeader(
                icon: AnyView(Image(systemName: place.symbol).font(.system(size: 11.5)).foregroundStyle(palette.label2)),
                title: place.name,
                collapsed: collapsed.contains(key),
                rollup: collapsed.contains(key) ? rollup(rows) : nil,
                selected: false,
                metrics: metrics, palette: palette, style: style.rows,
                select: nil,
                toggle: { toggle(key) },
                add: { _ in actions.newWorkspace(nil, place) }
            )
            if !collapsed.contains(key) { column(rows, member: true) }
        }
        .padding(.top, metrics.blockGap)
    }

    @ViewBuilder private func statusBlock(_ key: String, _ title: String, _ rows: [SidebarProjectsRow]) -> some View {
        if !rows.isEmpty {
            header(title, count: rows.count)
            column(rows)
        }
    }

    private func toggle(_ key: String) {
        withAnimation(.snappy(duration: 0.18)) {
            if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        }
    }

    @ViewBuilder private func projectIcon(_ project: SidebarProjectsGroup) -> some View {
        let palette = palette
        let tint = project.color.flatMap(Self.color(hex:))
        switch style.icon {
        case .letter:
            Text(String(project.name.prefix(1)).uppercased()).font(.system(size: 10.5, weight: .semibold))
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill(palette.wash(0.12)))
        case .color:
            Text(String(project.name.prefix(1)).uppercased()).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(tint ?? palette.label)
                .frame(width: 18, height: 18).background(RoundedRectangle(cornerRadius: 5).fill((tint ?? palette.label).opacity(0.2)))
        case .folder:
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(palette.label2)
        case .none:
            EmptyView()
        }
    }

    private static func color(hex: String) -> Color? {
        var value: UInt64 = 0
        guard Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value) else { return nil }
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// What a folded block says about its rows: the most urgent mark.
    private func rollup(_ rows: [SidebarProjectsRow]) -> AnyView? {
        let palette = palette
        if rows.contains(where: { $0.status == .failed }) { return AnyView(ProjectsDot(color: palette.err, size: 7)) }
        if rows.contains(where: { $0.status == .needsInput }) { return AnyView(ProjectsDot(color: style.status == .mono ? palette.label2 : palette.need, size: 7)) }
        let unread = rows.reduce(0) { $0 + $1.unread }
        if unread > 0 { return AnyView(ProjectsCountBadge(count: unread, fill: style.status == .mono ? palette.wash(0.16) : palette.accent, text: style.status == .mono ? palette.label : .white)) }
        if rows.contains(where: { $0.status == .working }) { return AnyView(ProjectsSpinner(size: 9, color: style.status == .mono ? palette.label2 : palette.accent)) }
        return nil
    }

    // MARK: Rows

    /// A run of rows you can drag to reorder among themselves.
    private func column(_ rows: [SidebarProjectsRow], member: Bool = false, pinnedSection: Bool = false) -> some View {
        ProjectsRowReorderStack(rows: rows, spacing: metrics.rowGap, palette: palette, radius: metrics.radius, onCommit: actions.reorderRows) { row in
            rowView(row, member: member, pinnedSection: pinnedSection)
        }
    }

    /// Where the row's title starts and its leading slot sits, from the row's content edge.
    private func columns(member: Bool) -> (slot: CGFloat, title: CGFloat) {
        let slot: CGFloat = style.leading == .none ? 0 : 27
        guard member else { return (0, slot) }
        let icon: CGFloat = style.groupBy == .project && style.icon == .none ? 0 : 27
        let title: CGFloat
        switch style.indent {
        case .aligned: title = max(icon, slot)
        case .indented: title = max(icon, slot) + 14
        case .tree: title = icon + slot
        }
        return (title - slot, title)
    }

    private func rowView(_ row: SidebarProjectsRow, member: Bool, pinnedSection: Bool) -> some View {
        let palette = palette
        let metrics = metrics
        let selected = selectedId == row.id
        let strong = selected || row.unread > 0 || row.status == .needsInput || row.status == .failed
        let columns = columns(member: member)
        return HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: columns.slot, height: 1)
            if style.leading != .none {
                // The slot keeps its width when empty, so every title in a run lines up.
                ZStack { leadingSlot(row, pinnedSection: pinnedSection) }
                    .frame(width: 18, height: metrics.lineHeight)
                Color.clear.frame(width: 9, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(row)).font(.system(size: metrics.title)).lineLimit(1)
                        .foregroundStyle(strong ? palette.label : palette.label2)
                    Spacer(minLength: 4)
                    trailing(row)
                }
                .frame(height: metrics.lineHeight)
                if style.lines == .two { detailLine(row) }
            }
        }
        .padding(.horizontal, metrics.pad)
        .padding(.vertical, style.lines == .two ? metrics.twoLinePad : 0)
        .frame(minHeight: style.lines == .two ? 0 : metrics.rowHeight)
        .modifier(ProjectsRowChrome(selected: selected, radius: metrics.radius, style: style.rows, palette: palette) { actions.select(row.id) })
        .modifier(ProjectsRightClick { point in menu = ProjectsMenuRequest(point: point, entries: workspaceMenu(row)) })
    }

    private func title(_ row: SidebarProjectsRow) -> String {
        switch style.title {
        case .name: return row.title
        case .task: return row.message ?? row.title
        case .directory: return row.directory.isEmpty ? row.title : row.directory
        case .branch: return row.branch ?? row.title
        }
    }

    @ViewBuilder private func leadingSlot(_ row: SidebarProjectsRow, pinnedSection: Bool) -> some View {
        let palette = palette
        switch style.leading {
        case .status:
            if let mark = mark(row) {
                mark
            } else if pinnedSection {
                Image(systemName: "pin").font(.system(size: 10)).foregroundStyle(palette.label3)
            }
        case .agent:
            ZStack(alignment: .bottomTrailing) {
                agentImage(row.agents.first, size: 15)
                if let badge = badge(row) { badge.offset(x: 4, y: 3) }
            }
        case .none:
            EmptyView()
        }
    }

    /// The status mark: spinner while working, a dot when it needs you or failed,
    /// the accent count for unread. Words style says needs input and failed in
    /// words at the trailing edge instead.
    private func mark(_ row: SidebarProjectsRow) -> AnyView? {
        let palette = palette
        let mono = style.status == .mono
        switch row.status {
        case .working:
            return AnyView(ProjectsSpinner(size: 10, color: mono ? palette.label2 : palette.accent))
        case .needsInput where style.status != .words:
            return AnyView(ProjectsDot(color: mono ? palette.label2 : palette.need, size: 8))
        case .failed where style.status != .words:
            return AnyView(mono ? AnyView(Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.label2)) : AnyView(ProjectsDot(color: palette.err, size: 8)))
        default:
            guard row.unread > 0 else { return nil }
            return AnyView(ProjectsCountBadge(count: row.unread, fill: mono ? palette.wash(0.16) : palette.accent, text: mono ? palette.label : .white))
        }
    }

    /// The same status, small, on the corner of the agent icon.
    private func badge(_ row: SidebarProjectsRow) -> AnyView? {
        let palette = palette
        let mono = style.status == .mono
        let ring: (AnyView) -> AnyView = { AnyView($0.padding(1.5).background(Circle().fill(palette.bg))) }
        switch row.status {
        case .working: return ring(AnyView(ProjectsSpinner(size: 7, color: mono ? palette.label2 : palette.accent)))
        case .needsInput where style.status != .words: return ring(AnyView(ProjectsDot(color: mono ? palette.label2 : palette.need, size: 6)))
        case .failed where style.status != .words: return ring(AnyView(ProjectsDot(color: mono ? palette.label2 : palette.err, size: 6)))
        default: return row.unread > 0 ? ring(AnyView(ProjectsDot(color: mono ? palette.label2 : palette.accent, size: 6))) : nil
        }
    }

    @ViewBuilder private func trailing(_ row: SidebarProjectsRow) -> some View {
        let palette = palette
        if style.leading == .none, let mark = mark(row) { mark }
        if style.status == .words, row.status == .needsInput || row.status == .failed {
            Text(row.status == .failed
                 ? String(localized: "sidebar.projects.failed", defaultValue: "Failed")
                 : String(localized: "sidebar.projects.needsInput", defaultValue: "Needs input"))
                .font(.system(size: metrics.detail, weight: .medium))
                .foregroundStyle(row.status == .failed ? palette.err : palette.label2)
                .fixedSize()
        }
        if style.machine != .hidden, style.groupBy != .machine, row.place != .local {
            HStack(spacing: 3) {
                Image(systemName: row.place.symbol).font(.system(size: 9.5))
                if style.machine == .name { Text(row.place.shortName).font(.system(size: metrics.detail)).lineLimit(1) }
            }
            .foregroundStyle(palette.label3).fixedSize()
            .help(row.place.name)
        }
        if style.agents, style.leading != .agent, !row.agents.isEmpty {
            HStack(spacing: 3) {
                ForEach(Array(Set(row.agents)).sorted(), id: \.self) { agentImage($0, size: 12) }
            }
            .opacity(0.85)
        }
        if style.time, let age = row.age {
            Text(age).font(.system(size: metrics.detail)).foregroundStyle(palette.label3).fixedSize()
        }
        if style.diff, let added = row.added, let removed = row.removed {
            HStack(spacing: 3) {
                Text("+\(added)").foregroundStyle(palette.add)
                Text("−\(removed)").foregroundStyle(palette.del)
            }
            .font(.system(size: metrics.detail - 1, design: .monospaced)).fixedSize()
        }
    }

    @ViewBuilder private func detailLine(_ row: SidebarProjectsRow) -> some View {
        let palette = palette
        HStack(spacing: 4) {
            switch style.detail {
            case .branch:
                if let branch = row.branch, style.title != .branch {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: metrics.detail - 2.5))
                    Text(branch).lineLimit(1)
                } else {
                    Text(row.directory).lineLimit(1).truncationMode(.head)
                }
            case .directory:
                Text(row.directory).lineLimit(1).truncationMode(.head)
            case .message:
                Text(row.message ?? statusWord(row) ?? row.directory).lineLimit(1)
            case .machine:
                Image(systemName: row.place.symbol).font(.system(size: metrics.detail - 2))
                Text(row.place.name).lineLimit(1)
            }
        }
        .font(.system(size: metrics.detail)).foregroundStyle(palette.label3)
    }

    private func statusWord(_ row: SidebarProjectsRow) -> String? {
        switch row.status {
        case .working: return String(localized: "sidebar.projects.working", defaultValue: "Working")
        case .needsInput: return String(localized: "sidebar.projects.needsInput", defaultValue: "Needs input")
        case .failed: return String(localized: "sidebar.projects.failed", defaultValue: "Failed")
        case .done, .idle: return nil
        }
    }

    @ViewBuilder private func agentImage(_ kind: String?, size: CGFloat) -> some View {
        if let kind, let image = agentIcon(kind) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "terminal").font(.system(size: size - 4)).foregroundStyle(palette.label2).frame(width: size, height: size)
        }
    }

    // MARK: Menus

    private func whereMenu(project: UUID?) -> [ProjectsMenuEntry] {
        var entries: [ProjectsMenuEntry] = places.map { place in
            .item(String(localized: "sidebar.projects.newOn", defaultValue: "New Workspace on \(place.name)"), symbol: place.symbol) {
                actions.newWorkspace(project, place)
            }
        }
        entries += [
            .separator,
            .item(String(localized: "sidebar.projects.newCloudMachine", defaultValue: "New Cloud Machine…"), symbol: "plus") {
                actions.newCloudMachine(project)
            },
        ]
        return entries
    }

    private var emptyAreaMenu: [ProjectsMenuEntry] {
        [
            .item(String(localized: "sidebar.projects.customizeEllipsis", defaultValue: "Customize Sidebar…"), symbol: "slider.horizontal.3") {
                store.isCustomizing = true
            },
            .separator,
            .item(String(localized: "sidebar.projects.newWorkspaceItem", defaultValue: "New Workspace"), symbol: "square.and.pencil") {
                actions.newWorkspace(nil, nil)
            },
            .item(String(localized: "sidebar.projects.newProject", defaultValue: "New Project"), symbol: "folder.badge.plus") {
                actions.newProject(nil)
            },
        ]
    }

    private func workspaceMenu(_ row: SidebarProjectsRow) -> [ProjectsMenuEntry] {
        Self.workspaceMenu(row, groups: groups, actions: actions)
    }

    /// A workspace's right-click menu; Panes, Flush and Machine tabs use it too.
    static func workspaceMenu(_ row: SidebarProjectsRow, groups: [SidebarProjectsGroup], actions: SidebarProjectsActions) -> [ProjectsMenuEntry] {
        let knownGroupIds = Set(groups.map(\.id))
        var entries: [ProjectsMenuEntry] = [
            .item(row.isPinned ? String(localized: "sidebar.projects.unpinWorkspace", defaultValue: "Unpin Workspace")
                               : String(localized: "sidebar.projects.pinWorkspace", defaultValue: "Pin Workspace"),
                  symbol: row.isPinned ? "pin.slash" : "pin") { actions.togglePin(row.id) },
            .item(row.unread > 0 ? String(localized: "sidebar.projects.markRead", defaultValue: "Mark as Read")
                                 : String(localized: "sidebar.projects.markUnread", defaultValue: "Mark as Unread"),
                  symbol: row.unread > 0 ? "envelope.open" : "envelope.badge") { actions.toggleRead(row.id) },
            .separator,
            .item(String(localized: "sidebar.projects.addToNewProject", defaultValue: "Add to New Project"), symbol: "folder.badge.plus") {
                actions.newProject(row.id)
            },
        ]
        for group in groups where group.id != row.groupId {
            entries.append(.item(String(localized: "sidebar.projects.moveTo", defaultValue: "Move to \(group.name)"), symbol: "folder") {
                actions.moveToProject(row.id, group.id)
            })
        }
        if let groupId = row.groupId, knownGroupIds.contains(groupId) {
            entries.append(.item(String(localized: "sidebar.projects.removeFromProject", defaultValue: "Remove from Project"), symbol: "folder.badge.minus") {
                actions.removeFromProject(row.id)
            })
        }
        entries += [
            .separator,
            .item(String(localized: "sidebar.projects.closeWorkspace", defaultValue: "Close Workspace"), symbol: "xmark", destructive: true) {
                actions.close(row.id)
            },
        ]
        return entries
    }

    private func projectMenu(_ project: SidebarProjectsGroup, members: [SidebarProjectsRow]) -> [ProjectsMenuEntry] {
        [
            .item(String(localized: "sidebar.projects.newInProject", defaultValue: "New Workspace in Project"), symbol: "plus") {
                actions.newWorkspace(project.id, nil)
            },
            .item(project.isPinned ? String(localized: "sidebar.projects.unpinProject", defaultValue: "Unpin Project")
                                   : String(localized: "sidebar.projects.pinProject", defaultValue: "Pin Project"),
                  symbol: project.isPinned ? "pin.slash" : "pin") { actions.toggleProjectPin(project.id) },
            .item(String(localized: "sidebar.projects.markAllRead", defaultValue: "Mark All as Read"), symbol: "envelope.open") {
                actions.markProjectRead(project.id)
            },
            .separator,
            .item(String(localized: "sidebar.projects.ungroupProject", defaultValue: "Ungroup Project"), symbol: "folder.badge.minus") {
                actions.ungroupProject(project.id)
            },
            .item(String(localized: "sidebar.projects.deleteProject", defaultValue: "Delete Project…"), symbol: "trash", destructive: true) {
                actions.deleteProject(project.id)
            },
        ]
    }

    // MARK: Metrics

    struct Metrics {
        let title, project, header, detail, nav: CGFloat
        let rowHeight, lineHeight, twoLinePad, rowGap, blockGap, radius, margin, pad: CGFloat

        init(style: SidebarProjectsStyle) {
            switch style.textSize {
            case .small: (title, project, header, detail, nav) = (12, 12.5, 9.5, 10.5, 12)
            case .medium: (title, project, header, detail, nav) = (13, 13.5, 10, 11.5, 13)
            case .large: (title, project, header, detail, nav) = (14, 14.5, 10.5, 12.5, 14)
            }
            switch style.density {
            case .compact: (rowHeight, twoLinePad) = (26, 4)
            case .regular: (rowHeight, twoLinePad) = (30, 6)
            case .roomy: (rowHeight, twoLinePad) = (34, 9)
            }
            lineHeight = title + 5
            switch style.rows {
            case .rounded: (rowGap, radius, margin, pad) = (1, 7, 10, 10)
            case .flush: (rowGap, radius, margin, pad) = (0, 0, 0, 20)
            }
            // Projects sit close: a folder list, not separate cards (Lucas, 2026-10-15).
            blockGap = style.rows == .flush ? 0 : 2
        }
    }
}

// MARK: - Pieces

/// A project's (or machine's) row: icon and name; on hover a + (new workspace
/// there) and the fold chevron. Clicking the row opens the project's own
/// workspace when it has one, otherwise folds it.
private struct BlockHeader: View {
    let icon: AnyView
    let title: String
    let collapsed: Bool
    let rollup: AnyView?
    let selected: Bool
    let metrics: SidebarProjectsView.Metrics
    let palette: SidebarProjectsPalette
    let style: SidebarProjectsStyle.Rows
    let select: (() -> Void)?
    let toggle: () -> Void
    let add: (CGPoint) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 18, height: 18)
            Text(title).font(.system(size: metrics.project, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            if !hovering, let rollup { rollup }
            if hovering {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.label2)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .global) { add($0) }
            }
            if hovering || collapsed {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.label3)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
            }
        }
        .padding(.leading, metrics.pad).padding(.trailing, metrics.pad - 4)
        .frame(height: metrics.rowHeight)
        .modifier(ProjectsRowChrome(selected: selected, radius: metrics.radius, style: style, palette: palette) {
            if let select { select() } else { toggle() }
        })
        .onHover { hovering = $0 }
    }
}

struct ProjectsRowChrome: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    let style: SidebarProjectsStyle.Rows
    let palette: SidebarProjectsPalette
    let action: () -> Void
    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        let fill: Double
        switch style {
        case .rounded: fill = selected ? 0.1 : hovering ? 0.045 : 0
        case .flush: fill = selected ? 0.09 : hovering ? 0.04 : 0
        }
        return content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(palette.wash(fill)))
            .overlay(alignment: .leading) {
                if style == .flush, selected { Rectangle().fill(palette.accent).frame(width: 2) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct ProjectsIconButton: View {
    let symbol: String
    let palette: SidebarProjectsPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: 11))
            .foregroundStyle(palette.label2)
            .frame(width: 22, height: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(palette.wash(hovering ? 0.1 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
    }
}

struct ProjectsDot: View {
    let color: Color
    let size: CGFloat
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct ProjectsCountBadge: View {
    let count: Int
    let fill: Color
    let text: Color
    var body: some View {
        Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(text)
            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(fill))
            .fixedSize()
    }
}

struct ProjectsSpinner: View {
    let size: CGFloat
    let color: Color
    @State private var spinning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

// MARK: - Drag to reorder (the native list's lift: soft spring, frames frozen at drag start)

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) { value.merge(nextValue()) { $1 } }
}

struct ProjectsRowReorderStack<Content: View>: View {
    let rows: [SidebarProjectsRow]
    let spacing: CGFloat
    let palette: SidebarProjectsPalette
    let radius: CGFloat
    let onCommit: ([UUID], [UUID]) -> Void
    @ViewBuilder let content: (SidebarProjectsRow) -> Content
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var dragging: UUID?
    @State private var translation: CGFloat = 0

    private var insertion: Int? {
        guard let dragging, let from = rows.firstIndex(where: { $0.id == dragging }) else { return nil }
        var top: CGFloat = 0
        var centers: [CGFloat] = []
        for row in rows {
            let height = heights[row.id] ?? 30
            centers.append(top + height / 2)
            top += height + spacing
        }
        let center = centers[from] + translation
        return rows.indices.filter { $0 != from && centers[$0] < center }.count
    }

    private func shift(for index: Int, insertion: Int?) -> CGFloat {
        guard let dragging, let insertion, let from = rows.firstIndex(where: { $0.id == dragging }), index != from else { return 0 }
        let step = (heights[dragging] ?? 30) + spacing
        let slot = index < from ? index : index - 1
        if index > from, slot < insertion { return -step }
        if index < from, slot >= insertion { return step }
        return 0
    }

    var body: some View {
        let insertion = insertion
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let lifted = dragging == row.id
                content(row)
                    .background(GeometryReader { geo in Color.clear.preference(key: RowHeightKey.self, value: [row.id: geo.size.height]) })
                    .background(RoundedRectangle(cornerRadius: max(radius, 6)).fill(palette.raise).opacity(lifted ? 1 : 0))
                    .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
                    .offset(y: lifted ? translation : shift(for: index, insertion: insertion))
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted ? nil : .interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: insertion)
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                if dragging == nil { dragging = row.id }
                                translation = value.translation.height
                            }
                            .onEnded { _ in drop() }
                    )
            }
        }
        .onPreferenceChange(RowHeightKey.self) { heights = $0 }
    }

    private func drop() {
        guard let dragging, let insertion else {
            self.dragging = nil
            translation = 0
            return
        }
        let old = rows.map(\.id)
        var new = old.filter { $0 != dragging }
        new.insert(dragging, at: min(insertion, new.count))
        withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.24)) {
            onCommit(old, new)
            self.dragging = nil
            translation = 0
        }
    }
}

/// Projects you drag by the header; the others glide aside on the same spring.
struct ProjectsBlockReorderStack<Content: View>: View {
    let ids: [UUID]
    let spacing: CGFloat
    let palette: SidebarProjectsPalette
    let onCommit: ([UUID]) -> Void
    @ViewBuilder let content: (UUID) -> Content
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var dragging: UUID?
    @State private var translation: CGFloat = 0

    private var insertion: Int? {
        guard let dragging, let from = ids.firstIndex(of: dragging) else { return nil }
        var top: CGFloat = 0
        var centers: [CGFloat] = []
        for id in ids {
            let height = heights[id] ?? 30
            centers.append(top + height / 2)
            top += height + spacing
        }
        // The dragged block's leading edge against the others' centers, so a tall
        // project does not have to travel its whole height to swap.
        let half = (heights[dragging] ?? 30) / 2
        let lead = translation < 0 ? centers[from] - half + translation : centers[from] + half + translation
        return ids.indices.filter { $0 != from && centers[$0] < lead }.count
    }

    private func shift(for id: UUID, insertion: Int?) -> CGFloat {
        guard let dragging, let insertion, id != dragging,
              let from = ids.firstIndex(of: dragging), let index = ids.firstIndex(of: id) else { return 0 }
        let step = (heights[dragging] ?? 30) + spacing
        let slot = index < from ? index : index - 1
        if index > from, slot < insertion { return -step }
        if index < from, slot >= insertion { return step }
        return 0
    }

    var body: some View {
        let insertion = insertion
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(ids, id: \.self) { id in
                let lifted = dragging == id
                content(id)
                    .background(GeometryReader { geo in Color.clear.preference(key: RowHeightKey.self, value: [id: geo.size.height]) })
                    .background(RoundedRectangle(cornerRadius: 7).fill(palette.raise).opacity(lifted ? 1 : 0))
                    .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 10 : 0, y: lifted ? 4 : 0)
                    .offset(y: lifted ? translation : shift(for: id, insertion: insertion))
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted ? nil : .interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: insertion)
                    .simultaneousGesture(
                        // Global space: the block moves under the pointer, so a local
                        // translation would chase its own offset and jitter.
                        DragGesture(minimumDistance: 5, coordinateSpace: .global)
                            .onChanged { value in
                                // Only a drag that starts on the header moves the project;
                                // rows inside handle their own drags.
                                if dragging == nil {
                                    guard value.startLocation.y - blockTop(id) < 34 else { return }
                                    dragging = id
                                }
                                if dragging == id { translation = value.translation.height }
                            }
                            .onEnded { _ in if dragging == id { drop() } }
                    )
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { tops[id] = $0 }
            }
        }
        .onPreferenceChange(RowHeightKey.self) { heights = $0 }
    }

    @State private var tops: [UUID: CGFloat] = [:]
    private func blockTop(_ id: UUID) -> CGFloat { tops[id] ?? .greatestFiniteMagnitude }

    private func drop() {
        guard let dragging, let insertion else {
            self.dragging = nil
            translation = 0
            return
        }
        var new = ids.filter { $0 != dragging }
        new.insert(dragging, at: min(insertion, new.count))
        withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.24)) {
            onCommit(new)
            self.dragging = nil
            translation = 0
        }
    }
}

// MARK: - Context menu (a panel on the sidebar's palette, dismissed like a system menu)

enum ProjectsMenuEntry {
    case item(String, symbol: String, destructive: Bool = false, action: () -> Void)
    case separator
}

struct ProjectsMenuRequest {
    let id = UUID()
    /// Where the click landed, in the window's top-left coordinates.
    let point: CGPoint
    let entries: [ProjectsMenuEntry]
}

/// Right-clicks (and control-clicks) over the content report their point; every
/// other event falls through to SwiftUI underneath.
struct ProjectsRightClick: ViewModifier {
    let action: (CGPoint) -> Void

    func body(content: Content) -> some View {
        content.overlay(Catcher(action: action))
    }

    struct Catcher: NSViewRepresentable {
        let action: (CGPoint) -> Void

        func makeNSView(context: Context) -> CatcherView {
            let view = CatcherView()
            view.action = action
            return view
        }

        func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
    }

    final class CatcherView: NSView {
        var action: ((CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { report(event) }
        override func mouseDown(with event: NSEvent) { report(event) }

        private func report(_ event: NSEvent) {
            guard let content = window?.contentView else { return }
            action?(CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y))
        }
    }
}

struct ProjectsMenuOverlay: View {
    let request: ProjectsMenuRequest
    let container: CGRect
    let palette: SidebarProjectsPalette
    let dismiss: () -> Void

    private static let width: CGFloat = 228
    private static let rowHeight: CGFloat = 26
    private static let separatorHeight: CGFloat = 9
    private static let inset: CGFloat = 5
    @State private var monitor: Any?
    @State private var resignObserver: NSObjectProtocol?

    private var height: CGFloat {
        request.entries.reduce(Self.inset * 2) { total, entry in
            if case .separator = entry { return total + Self.separatorHeight }
            return total + Self.rowHeight
        }
    }

    /// Opens at the click, flipped up or pulled in where it would leave the sidebar.
    private var origin: CGPoint {
        let x = request.point.x - container.minX, y = request.point.y - container.minY
        return CGPoint(
            x: max(6, min(x, container.width - Self.width - 6)),
            y: y + height > container.height - 6 ? max(6, y - height) : y
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(Array(request.entries.enumerated()), id: \.offset) { _, entry in
                    switch entry {
                    case .separator:
                        Rectangle().fill(palette.sep).frame(height: 1)
                            .padding(.horizontal, 8).frame(height: Self.separatorHeight)
                    case .item(let title, let symbol, let destructive, let action):
                        MenuRow(title: title, symbol: symbol, destructive: destructive, palette: palette) {
                            dismiss()
                            action()
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
            }
            .padding(Self.inset)
            .frame(width: Self.width)
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.raise))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.wash(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(palette.isDark ? 0.5 : 0.18), radius: 16, y: 6)
            .offset(x: origin.x, y: origin.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: watchForDismissal)
        .onDisappear(perform: stopWatching)
    }

    /// A click anywhere outside the panel, Escape, or the window losing focus
    /// closes it. The closing left click is swallowed; a right click passes on
    /// so it can open the next menu.
    private func watchForDismissal() {
        let panel = CGRect(x: container.minX + origin.x, y: container.minY + origin.y, width: Self.width, height: height)
        let dismiss = dismiss
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }
                dismiss()
                return nil
            }
            if let content = event.window?.contentView {
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                if panel.contains(point) { return event }
            }
            dismiss()
            return event.type == .leftMouseDown && !event.modifierFlags.contains(.control) ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { _ in
            dismiss()
        }
    }

    private func stopWatching() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }
}

private struct MenuRow: View {
    let title: String
    let symbol: String
    let destructive: Bool
    let palette: SidebarProjectsPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11.5)).frame(width: 16)
                .foregroundStyle(destructive ? palette.err : palette.label2)
            Text(title).font(.system(size: 13)).lineLimit(1)
                .foregroundStyle(destructive ? palette.err : palette.label)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.wash(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
    }
}
