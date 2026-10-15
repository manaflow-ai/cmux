import AppKit
import SwiftUI

// Panes, Flush and Machine tabs (design/sidebar-variations.html N1, N4, N7):
// custom sidebars, each its own design, fed the same rows, projects and
// actions as the Projects sidebar. The same file runs in labs/SidebarLab,
// fed from the lab's fake data.

/// One pane inside a workspace, for the Panes sidebar: an agent, a shell, a
/// browser, a display.
struct SidebarLayoutPane: Identifiable, Equatable {
    enum Kind: Equatable { case agent(String), shell, browser, display, other }
    /// The pane's panel id in the app.
    let id: String
    let kind: Kind
    let text: String
    var detail: String?
    var status = SidebarProjectsRow.Status.idle
}

/// What these sidebars ask of their host on top of the Projects actions.
struct SidebarLayoutActions {
    var focusPane: (UUID, SidebarLayoutPane) -> Void = { _, _ in }
    var openPort: (UUID, Int) -> Void = { _, _ in }
    /// Machine card buttons; nil hides one the host can't do.
    var newTerminal: ((SidebarProjectsRow.Place) -> Void)?
    var openDisplay: ((SidebarProjectsRow.Place) -> Void)?
    var sleepMachine: ((SidebarProjectsRow.Place) -> Void)?
}

/// Everything Panes, Flush and Machine tabs read.
struct SidebarLayoutInput {
    var rows: [SidebarProjectsRow] = []
    var groups: [SidebarProjectsGroup] = []
    var selectedId: UUID?
    /// Cloud machines and devices the user has beyond the rows' own.
    var machines: [SidebarProjectsRow.Place] = []
    /// Space left for the titlebar controls, and kept clear for the app's footer.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var actions = SidebarProjectsActions()
    var more = SidebarLayoutActions()
    var agentIcon: (String) -> NSImage? = { _ in nil }
    /// A workspace's panes, asked for only when a row shows them.
    var panes: (UUID) -> [SidebarLayoutPane] = { _ in [] }
    /// What a machine is and whether it's up; nil parts are left out.
    var machineFacts: (SidebarProjectsRow.Place) -> (state: String?, spec: String?) = { _ in (nil, nil) }

    struct Bucket: Identifiable {
        let id: String
        let name: String
        let groupId: UUID?
        let rows: [SidebarProjectsRow]
    }

    /// Projects in order, each with every workspace in it (its own header
    /// workspace first, so none hides behind a name), then the ones in none.
    var buckets: [Bucket] {
        let known = Set(groups.map(\.id))
        var result: [Bucket] = groups.compactMap { group in
            var members = rows.filter { $0.groupId == group.id }
            if let anchor = group.anchorId, let index = members.firstIndex(where: { $0.id == anchor }) {
                members.insert(members.remove(at: index), at: 0)
            }
            return members.isEmpty ? nil : Bucket(id: group.id.uuidString, name: group.name, groupId: group.id, rows: members)
        }
        let loose = rows.filter { $0.groupId.map { !known.contains($0) } ?? true }
        if !loose.isEmpty {
            result.append(Bucket(id: "", name: String(localized: "sidebar.layouts.workspaces", defaultValue: "Workspaces"), groupId: nil, rows: loose))
        }
        return result
    }

    /// This Mac, then Cloud machines, then other devices, each in first-seen order.
    var places: [SidebarProjectsRow.Place] {
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

    func needsYou(_ row: SidebarProjectsRow) -> Bool { row.status == .needsInput || row.status == .failed }

    /// The agent's icon, or a terminal when the workspace has none.
    @ViewBuilder func agentImage(_ kind: String?, size: CGFloat, palette: SidebarProjectsPalette) -> some View {
        if let kind, let image = agentIcon(kind) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: "terminal").font(.system(size: size - 3)).foregroundStyle(palette.label2)
                .frame(width: size, height: size)
        }
    }

    /// Needs you, failed, or (idle) an outline.
    func stateDot(_ status: SidebarProjectsRow.Status, size: CGFloat, palette: SidebarProjectsPalette) -> some View {
        let color: Color
        switch status {
        case .needsInput: color = palette.need
        case .failed: color = palette.err
        case .working: color = palette.accent
        case .done: color = palette.label2
        case .idle: color = palette.label3
        }
        return Circle().fill(status == .idle ? Color.clear : color)
            .overlay(Circle().strokeBorder(status == .idle ? color : .clear, lineWidth: 1.5))
            .frame(width: size, height: size)
    }

    /// A workspace's machine at the row's end: glyph and short name, nothing on This Mac.
    @ViewBuilder func machineMark(_ row: SidebarProjectsRow, size: CGFloat) -> some View {
        if row.place != .local {
            HStack(spacing: 3) {
                Image(systemName: row.place.symbol).font(.system(size: size - 2))
                Text(row.place.shortName)
            }
            .fixedSize()
        }
    }
}

/// A field-looking button that opens the workspace switcher.
private struct SearchButton: View {
    let palette: SidebarProjectsPalette
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11))
            Text(String(localized: "sidebar.layouts.search", defaultValue: "Search workspaces…")).font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.label3)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// The dark right-click menu every one of these sidebars shares with Projects.
private struct MenuHost: ViewModifier {
    @Binding var menu: ProjectsMenuRequest?
    let palette: SidebarProjectsPalette
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .overlay {
                if let menu { ProjectsMenuOverlay(request: menu, container: frame, palette: palette) { self.menu = nil }.id(menu.id) }
            }
    }
}

// MARK: - Panes (Warp-like): what's inside a workspace

/// Every workspace is one quiet line; the one you're in opens to show its
/// panes (agents, shells, browsers, displays), and a workspace that needs you
/// opens just far enough to show the pane that's asking.
struct SidebarPanesView: View {
    let input: SidebarLayoutInput
    /// Which workspaces show their panes: "selected" (and any that need you), "all", or "none".
    @AppStorage("sidebarPanesExpand") private var expand = "selected"
    @AppStorage("sidebarPanesTitle") private var titleAs = "title"
    @State private var showsOptions = false
    @State private var menu: ProjectsMenuRequest?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SidebarProjectsPalette { SidebarProjectsPalette(dark: colorScheme == .dark, accent: .blue) }

    var body: some View {
        let palette = palette
        let buckets = input.buckets
        let projects = buckets.filter { $0.groupId != nil }
        VStack(spacing: 0) {
            Color.clear.frame(height: input.topInset)
            HStack(spacing: 4) {
                SearchButton(palette: palette, action: input.actions.search)
                ProjectsIconButton(symbol: "slider.horizontal.3", palette: palette) { showsOptions.toggle() }
                    .popover(isPresented: $showsOptions, arrowEdge: .bottom) { options }
                ProjectsIconButton(symbol: "plus", palette: palette) { input.actions.newWorkspace(nil, nil) }
            }
            .padding(.leading, 8).padding(.trailing, 4).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(palette.wash(0.06)))
            .padding(.horizontal, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ProjectsBlockReorderStack(ids: projects.compactMap(\.groupId), spacing: 2, palette: palette, onCommit: input.actions.reorderGroups) { id in
                        if let bucket = projects.first(where: { $0.groupId == id }) { block(bucket) }
                    }
                    if let loose = buckets.first(where: { $0.groupId == nil }) { block(loose) }
                }
                .padding(.horizontal, 8).padding(.bottom, 10 + input.bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(palette.label)
        .background(palette.bg)
        .modifier(MenuHost(menu: $menu, palette: palette))
        .animation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: input.rows.map(\.id))
    }

    private func block(_ bucket: SidebarLayoutInput.Bucket) -> some View {
        let palette = palette
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(bucket.name).font(.system(size: 11.5, weight: .semibold))
                Text("\(bucket.rows.count)").font(.system(size: 11))
                Spacer()
            }
            .foregroundStyle(palette.label3)
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 2)
            ProjectsRowReorderStack(rows: bucket.rows, spacing: 1, palette: palette, radius: 9, onCommit: input.actions.reorderRows) { row in
                workspace(row)
            }
        }
    }

    private func title(_ row: SidebarProjectsRow) -> String {
        switch titleAs {
        case "task": return row.message ?? row.title
        case "dir": return row.directory.isEmpty ? row.title : row.directory
        case "branch": return row.branch ?? row.title
        default: return row.title
        }
    }

    /// All of the open workspace's panes, only the asking one for a workspace
    /// that needs you, none otherwise.
    private func shownPanes(_ row: SidebarProjectsRow) -> [SidebarLayoutPane] {
        switch expand {
        case "all": return input.panes(row.id)
        case "none": return []
        default:
            if input.selectedId == row.id { return input.panes(row.id) }
            guard input.needsYou(row) else { return [] }
            return input.panes(row.id).filter { $0.status == .needsInput || $0.status == .failed }
        }
    }

    private func workspace(_ row: SidebarProjectsRow) -> some View {
        let palette = palette
        let selected = input.selectedId == row.id
        let strong = selected || input.needsYou(row) || row.unread > 0
        let panes = shownPanes(row)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    Circle().fill(palette.wash(0.08)).frame(width: 22, height: 22)
                        .overlay(input.agentImage(row.agents.first, size: 13, palette: palette))
                    badge(row).offset(x: 3, y: 3)
                }
                .frame(width: 22, height: 22)
                Text(title(row)).font(.system(size: 13, weight: strong ? .medium : .regular)).lineLimit(1)
                    .foregroundStyle(strong ? palette.label : palette.label2)
                Spacer(minLength: 4)
                input.machineMark(row, size: 11.5).font(.system(size: 11)).foregroundStyle(palette.label3)
            }
            .padding(.horizontal, 8).frame(height: 32)
            if !panes.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(panes) { pane($0, in: row) }
                }
                .padding(.leading, 31).padding(.trailing, 4).padding(.bottom, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .modifier(ProjectsRowChrome(selected: selected, radius: 9, style: .rounded, palette: palette) { input.actions.select(row.id) })
        .modifier(ProjectsRightClick { point in
            menu = ProjectsMenuRequest(point: point, entries: SidebarProjectsView.workspaceMenu(row, groups: input.groups, actions: input.actions))
        })
        .animation(.snappy(duration: 0.2), value: panes.map(\.id))
    }

    private func pane(_ pane: SidebarLayoutPane, in row: SidebarProjectsRow) -> some View {
        let palette = palette
        let asking = pane.status == .needsInput || pane.status == .failed
        return HStack(spacing: 7) {
            Group {
                switch pane.kind {
                case .agent(let kind): input.agentImage(kind, size: 12, palette: palette)
                case .shell: Image(systemName: "terminal").font(.system(size: 9.5))
                case .browser: Image(systemName: "globe").font(.system(size: 10))
                case .display: Image(systemName: "display").font(.system(size: 9.5))
                case .other: Image(systemName: "doc").font(.system(size: 9.5))
                }
            }
            .foregroundStyle(palette.label3).frame(width: 14)
            Text(pane.text).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(asking ? palette.label : palette.label2)
            Spacer(minLength: 4)
            switch pane.status {
            case .working: ProjectsSpinner(size: 8, color: palette.accent)
            case .needsInput, .failed: input.stateDot(pane.status, size: 6, palette: palette)
            default:
                if let detail = pane.detail {
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(palette.label3).lineLimit(1).truncationMode(.head)
                }
            }
        }
        .padding(.horizontal, 6).frame(height: 24)
        .modifier(ProjectsRowChrome(selected: false, radius: 6, style: .rounded, palette: palette) { input.more.focusPane(row.id, pane) })
    }

    /// The workspace's state on the corner of its agent: spinner, needs-you dot, unread dot.
    @ViewBuilder private func badge(_ row: SidebarProjectsRow) -> some View {
        let palette = palette
        switch row.status {
        case .working: ProjectsSpinner(size: 7, color: palette.accent).padding(1.5).background(Circle().fill(palette.bg))
        case .needsInput, .failed: input.stateDot(row.status, size: 7, palette: palette).padding(1.5).background(Circle().fill(palette.bg))
        default:
            if row.unread > 0 { Circle().fill(palette.accent).frame(width: 7, height: 7).padding(1.5).background(Circle().fill(palette.bg)) }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(String(localized: "sidebar.layouts.panes.show", defaultValue: "Show panes"), selection: $expand) {
                Text(String(localized: "sidebar.layouts.panes.show.selected", defaultValue: "Open workspace")).tag("selected")
                Text(String(localized: "sidebar.layouts.panes.show.all", defaultValue: "Every workspace")).tag("all")
                Text(String(localized: "sidebar.layouts.panes.show.none", defaultValue: "Never")).tag("none")
            }
            .pickerStyle(.radioGroup)
            Picker(String(localized: "sidebar.layouts.panes.title", defaultValue: "Title shows"), selection: $titleAs) {
                Text(String(localized: "sidebar.layouts.panes.title.name", defaultValue: "Workspace name")).tag("title")
                Text(String(localized: "sidebar.layouts.panes.title.message", defaultValue: "Latest message")).tag("task")
                Text(String(localized: "sidebar.layouts.panes.title.directory", defaultValue: "Directory")).tag("dir")
                Text(String(localized: "sidebar.layouts.panes.title.branch", defaultValue: "Branch")).tag("branch")
            }
            .pickerStyle(.radioGroup)
        }
        .padding(14).frame(width: 230)
    }
}

// MARK: - Flush (Zed-like): what each agent said

/// Edge to edge, like Zed's threads: the second line is what the agent last
/// said (or asked), so you can read the room without opening anything.
struct SidebarFlushView: View {
    let input: SidebarLayoutInput
    @State private var menu: ProjectsMenuRequest?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SidebarProjectsPalette { SidebarProjectsPalette(dark: colorScheme == .dark, accent: .blue) }

    var body: some View {
        let palette = palette
        let buckets = input.buckets
        let projects = buckets.filter { $0.groupId != nil }
        VStack(spacing: 0) {
            Color.clear.frame(height: input.topInset)
            Rectangle().fill(palette.sep).frame(height: 1)
            SearchButton(palette: palette, action: input.actions.search)
                .padding(.horizontal, 12).frame(height: 32)
            Rectangle().fill(palette.sep).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ProjectsBlockReorderStack(ids: projects.compactMap(\.groupId), spacing: 0, palette: palette, onCommit: input.actions.reorderGroups) { id in
                        if let bucket = projects.first(where: { $0.groupId == id }) { block(bucket) }
                    }
                    if let loose = buckets.first(where: { $0.groupId == nil }) { block(loose) }
                }
                .padding(.bottom, 10 + input.bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(palette.label)
        .background(palette.isDark ? Color(white: 0.067) : Color(white: 0.957))
        .modifier(MenuHost(menu: $menu, palette: palette))
        .animation(.interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: input.rows.map(\.id))
    }

    private func block(_ bucket: SidebarLayoutInput.Bucket) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Header(name: bucket.name, count: bucket.rows.count, palette: palette) { input.actions.newWorkspace(bucket.groupId, nil) }
            ProjectsRowReorderStack(rows: bucket.rows, spacing: 0, palette: palette, radius: 0, onCommit: input.actions.reorderRows) { row in
                self.row(row)
            }
        }
    }

    /// The second line: the agent's last words, else what it's doing, else where it is.
    private func line(_ row: SidebarProjectsRow) -> String {
        if let message = row.message, !message.isEmpty { return message }
        if row.status == .working { return String(localized: "sidebar.layouts.working", defaultValue: "Working") }
        return row.branch ?? row.directory
    }

    private func row(_ row: SidebarProjectsRow) -> some View {
        let palette = palette
        let selected = input.selectedId == row.id
        let strong = input.needsYou(row) || row.unread > 0
        return HStack(alignment: .top, spacing: 9) {
            Group {
                if row.status == .working {
                    ProjectsSpinner(size: 11, color: palette.accent)
                } else {
                    input.agentImage(row.agents.first, size: 14, palette: palette)
                }
            }
            .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: strong ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(selected || strong ? palette.label : palette.label2)
                    Spacer(minLength: 4)
                    if input.needsYou(row) {
                        input.stateDot(row.status, size: 7, palette: palette)
                    } else if row.unread > 0 {
                        Circle().fill(palette.accent).frame(width: 7, height: 7)
                    }
                }
                .frame(height: 18)
                HStack(spacing: 6) {
                    Text(line(row)).lineLimit(1)
                        .foregroundStyle(row.status == .needsInput ? palette.label2 : palette.label3)
                    Spacer(minLength: 4)
                    input.machineMark(row, size: 11)
                    if let age = row.age { Text(age).fixedSize() }
                }
                .font(.system(size: 11.5)).foregroundStyle(palette.label3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .modifier(ProjectsRowChrome(selected: selected, radius: 0, style: .flush, palette: palette) { input.actions.select(row.id) })
        .modifier(ProjectsRightClick { point in
            menu = ProjectsMenuRequest(point: point, entries: SidebarProjectsView.workspaceMenu(row, groups: input.groups, actions: input.actions))
        })
    }

    /// A project's name and count; + appears on hover.
    private struct Header: View {
        let name: String
        let count: Int
        let palette: SidebarProjectsPalette
        let add: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                Text(name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(palette.label2)
                Text("\(count)").font(.system(size: 11.5)).foregroundStyle(palette.label3)
                Spacer()
                ProjectsIconButton(symbol: "plus", palette: palette, action: add).opacity(hovering ? 1 : 0)
            }
            .padding(.leading, 12).padding(.trailing, 8).frame(height: 30).padding(.top, 8)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }
}

// MARK: - Machine tabs (Kiro-like): one machine at a time

/// A tab per machine, then that machine as a place you work in: what it is and
/// whether it's up, what to do with it, what needs you there, and what it's
/// serving (ports and displays).
struct SidebarMachineTabsView: View {
    let input: SidebarLayoutInput
    @State private var chosen = SidebarProjectsRow.Place.local
    @State private var menu: ProjectsMenuRequest?
    @Environment(\.colorScheme) private var colorScheme

    private var palette: SidebarProjectsPalette { SidebarProjectsPalette(dark: colorScheme == .dark, accent: .blue) }

    /// The chosen machine, or This Mac once it's gone.
    private var machine: SidebarProjectsRow.Place { input.places.contains(chosen) ? chosen : .local }

    var body: some View {
        let palette = palette
        let machine = machine
        let rows = input.rows.filter { $0.place == machine }
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: input.topInset)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(input.places, id: \.self) { place in
                        tab(place, needs: input.rows.filter { $0.place == place && input.needsYou($0) }.count)
                    }
                    ProjectsIconButton(symbol: "plus", palette: palette) { input.actions.newCloudMachine(nil) }
                        .help(String(localized: "sidebar.projects.newCloudMachine", defaultValue: "New Cloud Machine…"))
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 30)
            card(rows)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    section(String(localized: "sidebar.projects.needsYou", defaultValue: "Needs you"), rows.filter { input.needsYou($0) }, detail: true)
                    section(String(localized: "sidebar.projects.working", defaultValue: "Working"), rows.filter { $0.status == .working })
                    section(String(localized: "sidebar.projects.workspaces", defaultValue: "Workspaces"), rows.filter { $0.status == .done || $0.status == .idle })
                    ports(rows)
                    displays(rows)
                    if rows.isEmpty {
                        VStack(spacing: 8) {
                            Text(machine == .local
                                 ? String(localized: "sidebar.layouts.machine.emptyLocal", defaultValue: "Nothing on this Mac yet")
                                 : String(localized: "sidebar.layouts.machine.empty", defaultValue: "Nothing on \(machine.name) yet"))
                                .font(.system(size: 12)).foregroundStyle(palette.label3)
                            Button(String(localized: "sidebar.projects.newWorkspace", defaultValue: "New workspace")) {
                                input.actions.newWorkspace(nil, machine)
                            }
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 28)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10 + input.bottomInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(palette.label)
        .background(palette.bg)
        .modifier(MenuHost(menu: $menu, palette: palette))
    }

    // MARK: Tabs and the machine card

    private func tab(_ place: SidebarProjectsRow.Place, needs: Int) -> some View {
        let palette = palette
        let on = place == machine
        let up = input.machineFacts(place).state != nil
        return HStack(spacing: 5) {
            Image(systemName: place.symbol).font(.system(size: 10.5))
                .overlay(alignment: .bottomTrailing) {
                    if place != .local, up { Circle().fill(palette.add).frame(width: 5, height: 5).offset(x: 3, y: 1) }
                }
            Text(place == .local ? String(localized: "sidebar.layouts.local", defaultValue: "Local") : place.shortName).lineLimit(1)
            if needs > 0 {
                Text("\(needs)").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                    .frame(minWidth: 14, minHeight: 14).background(Capsule().fill(palette.need))
            }
        }
        .font(.system(size: 12, weight: on ? .medium : .regular))
        .foregroundStyle(on ? palette.label : palette.label2)
        .padding(.horizontal, 9).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7).fill(palette.wash(on ? 0.1 : 0)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.2)) { chosen = place } }
        .help(place.name)
    }

    /// What the machine is, whether it's up, and what to do with it.
    private func card(_ rows: [SidebarProjectsRow]) -> some View {
        let palette = palette
        let machine = machine
        let facts = input.machineFacts(machine)
        let working = rows.filter { $0.status == .working }.count
        let isCloud: Bool = { if case .cloud = machine { return true } else { return false } }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: machine.symbol).font(.system(size: 15)).foregroundStyle(palette.label2)
                    .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 8).fill(palette.wash(0.07)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(machine.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let state = facts.state {
                            HStack(spacing: 4) {
                                Circle().fill(palette.add).frame(width: 6, height: 6)
                                Text(state)
                            }
                            .font(.system(size: 11)).foregroundStyle(palette.label2).fixedSize()
                        }
                    }
                    if let spec = facts.spec {
                        Text(spec).lineLimit(1).font(.system(size: 11)).foregroundStyle(palette.label3)
                    }
                }
            }
            HStack(spacing: 6) {
                Action(symbol: "plus", title: String(localized: "sidebar.layouts.machine.workspace", defaultValue: "Workspace"), labeled: true, palette: palette) {
                    input.actions.newWorkspace(nil, machine)
                }
                if let newTerminal = input.more.newTerminal {
                    Action(symbol: "terminal", title: String(localized: "sidebar.layouts.machine.terminal", defaultValue: "New terminal"), palette: palette) { newTerminal(machine) }
                }
                if isCloud, let openDisplay = input.more.openDisplay {
                    Action(symbol: "display", title: String(localized: "sidebar.layouts.machine.display", defaultValue: "Open display"), palette: palette) { openDisplay(machine) }
                }
                if isCloud, let sleep = input.more.sleepMachine {
                    Action(symbol: "moon", title: String(localized: "sidebar.layouts.machine.sleep", defaultValue: "Sleep"), palette: palette) { sleep(machine) }
                }
                Spacer(minLength: 0)
            }
            Text(countLine(rows.count, working: working)).font(.system(size: 11)).foregroundStyle(palette.label3)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.wash(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.wash(0.07), lineWidth: 1))
    }

    private func countLine(_ count: Int, working: Int) -> String {
        let workspaces = count == 1
            ? String(localized: "sidebar.layouts.machine.oneWorkspace", defaultValue: "1 workspace")
            : String(localized: "sidebar.layouts.machine.workspaces", defaultValue: "\(count) workspaces")
        guard working > 0 else { return workspaces }
        return workspaces + " · " + String(localized: "sidebar.layouts.machine.working", defaultValue: "\(working) working")
    }

    // MARK: Sections

    @ViewBuilder private func section(_ title: String, _ rows: [SidebarProjectsRow], detail: Bool = false) -> some View {
        if !rows.isEmpty {
            let palette = palette
            header(title, count: rows.count)
            ForEach(rows) { row in
                let selected = input.selectedId == row.id
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 9) {
                        ZStack {
                            switch row.status {
                            case .working: ProjectsSpinner(size: 10, color: palette.accent)
                            case .needsInput, .failed: input.stateDot(row.status, size: 8, palette: palette)
                            default:
                                if row.unread > 0 {
                                    ProjectsCountBadge(count: row.unread, fill: palette.accent, text: .white)
                                } else {
                                    input.agentImage(row.agents.first, size: 13, palette: palette).opacity(0.8)
                                }
                            }
                        }
                        .frame(width: 16)
                        Text(row.title).font(.system(size: 13)).lineLimit(1)
                            .foregroundStyle(selected || row.unread > 0 || detail ? palette.label : palette.label2)
                        Spacer(minLength: 4)
                        if let age = row.age { Text(age).font(.system(size: 11)).foregroundStyle(palette.label3) }
                    }
                    .frame(height: 22)
                    if detail, let message = row.message {
                        Text(message).font(.system(size: 11.5)).foregroundStyle(palette.label2).lineLimit(2)
                            .padding(.leading, 25).padding(.bottom, 3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .modifier(ProjectsRowChrome(selected: selected, radius: 8, style: .rounded, palette: palette) { input.actions.select(row.id) })
                .modifier(ProjectsRightClick { point in
                    menu = ProjectsMenuRequest(point: point, entries: SidebarProjectsView.workspaceMenu(row, groups: input.groups, actions: input.actions))
                })
            }
        }
    }

    @ViewBuilder private func ports(_ rows: [SidebarProjectsRow]) -> some View {
        let served = rows.flatMap { row in row.ports.map { (port: $0, row: row) } }
        if !served.isEmpty {
            let palette = palette
            header(String(localized: "sidebar.layouts.machine.ports", defaultValue: "Ports"), count: served.count)
            ForEach(Array(served.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 9) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(palette.label3).frame(width: 16)
                    Text(verbatim: ":\(item.port)").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(palette.label)
                    Text(item.row.title).font(.system(size: 12)).foregroundStyle(palette.label3).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(palette.label3)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .modifier(ProjectsRowChrome(selected: false, radius: 8, style: .rounded, palette: palette) { input.more.openPort(item.row.id, item.port) })
            }
        }
    }

    @ViewBuilder private func displays(_ rows: [SidebarProjectsRow]) -> some View {
        let shown = rows.filter(\.isDisplay)
        if !shown.isEmpty {
            let palette = palette
            header(String(localized: "sidebar.layouts.machine.displays", defaultValue: "Displays"), count: shown.count)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: 9) {
                    Image(systemName: "display").font(.system(size: 11)).foregroundStyle(palette.label3).frame(width: 16)
                    Text(String(localized: "sidebar.layouts.machine.display.name", defaultValue: "Display \(index + 1)")).font(.system(size: 12.5)).foregroundStyle(palette.label)
                    Text(row.title).font(.system(size: 12)).foregroundStyle(palette.label3).lineLimit(1)
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 8).frame(height: 28)
                .modifier(ProjectsRowChrome(selected: false, radius: 8, style: .rounded, palette: palette) { input.actions.select(row.id) })
            }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold))
            Text("\(count)").font(.system(size: 11)).opacity(0.8)
        }
        .foregroundStyle(palette.label3)
        .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
    }

    /// A machine action: the main one says its name, the others are icons with a tooltip.
    private struct Action: View {
        let symbol: String
        let title: String
        var labeled = false
        let palette: SidebarProjectsPalette
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                if labeled { Text(title).font(.system(size: 11.5)) }
            }
            .foregroundStyle(palette.label2)
            .padding(.horizontal, labeled ? 9 : 0).frame(width: labeled ? nil : 26, height: 24)
            .help(title)
            .background(Capsule().fill(palette.wash(hovering ? 0.11 : 0.06)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
        }
    }
}
