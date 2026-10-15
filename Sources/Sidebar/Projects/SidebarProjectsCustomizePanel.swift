import SwiftUI

/// The Customize popover: pick a template, then change anything. Every control
/// writes the live style, so the sidebar beside it updates as you go.
struct SidebarProjectsCustomizePanel: View {
    @ObservedObject var store: SidebarProjectsStyleStore
    @AppStorage("sidebarProjectsCustomizePage") private var page = Page.layout

    enum Page: String, CaseIterable { case layout, rows, look }

    typealias Style = SidebarProjectsStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "sidebar.projects.customize.title", defaultValue: "Customize Sidebar"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.isEdited {
                    Button(String(localized: "sidebar.projects.customize.reset", defaultValue: "Reset")) { store.reset() }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            FlowLayout(spacing: 6) {
                ForEach(Style.templates) { template in
                    if template.name == store.templateName {
                        Button(template.name) { store.use(template) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(template.name) { store.use(template) }.buttonStyle(.bordered)
                    }
                }
            }
            .controlSize(.small)
            .buttonBorderShape(.capsule)
            .padding(.horizontal, 16)

            Text(store.isEdited
                 ? String(localized: "sidebar.projects.customize.edited", defaultValue: "\(store.template.summary). Edited.")
                 : store.template.summary)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.top, 8)

            Picker("", selection: $page) {
                Text(String(localized: "sidebar.projects.customize.layout", defaultValue: "Layout")).tag(Page.layout)
                Text(String(localized: "sidebar.projects.customize.rows", defaultValue: "Rows")).tag(Page.rows)
                Text(String(localized: "sidebar.projects.customize.look", defaultValue: "Look")).tag(Page.look)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch page {
                    case .layout: layout
                    case .rows: rows
                    case .look: look
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
        }
        .frame(width: 340, height: 600)
    }

    // MARK: Pages

    @ViewBuilder private var layout: some View {
        Group {
            Row(String(localized: "sidebar.projects.customize.groupBy", defaultValue: "Group by")) {
                Picker("", selection: bind(\.groupBy)) {
                    Text(String(localized: "sidebar.projects.customize.groupBy.project", defaultValue: "Project")).tag(Style.GroupBy.project)
                    Text(String(localized: "sidebar.projects.customize.groupBy.machine", defaultValue: "Machine")).tag(Style.GroupBy.machine)
                    Text(String(localized: "sidebar.projects.customize.groupBy.status", defaultValue: "Status")).tag(Style.GroupBy.status)
                    Text(String(localized: "sidebar.projects.customize.groupBy.none", defaultValue: "Nothing")).tag(Style.GroupBy.none)
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.indent", defaultValue: "Indent")) {
                segmented(bind(\.indent), [
                    (.aligned, String(localized: "sidebar.projects.customize.indent.aligned", defaultValue: "Aligned")),
                    (.indented, String(localized: "sidebar.projects.customize.indent.indented", defaultValue: "Indented")),
                    (.tree, String(localized: "sidebar.projects.customize.indent.tree", defaultValue: "Tree")),
                ])
            }
        }
        .modifier(Box(title: nil))

        SectionOrder(store: store, name: name)
            .modifier(Box(
                title: String(localized: "sidebar.projects.customize.sections", defaultValue: "Sections"),
                footer: String(localized: "sidebar.projects.customize.sections.footer", defaultValue: "Drag the handles to change the order.")
            ))

        Group {
            Row(String(localized: "sidebar.projects.customize.newWorkspace", defaultValue: "New workspace")) {
                segmented(bind(\.newButton), [
                    (.button, String(localized: "sidebar.projects.customize.new.button", defaultValue: "Button")),
                    (.row, String(localized: "sidebar.projects.customize.new.row", defaultValue: "Row")),
                    (.hidden, String(localized: "sidebar.projects.customize.new.hidden", defaultValue: "Hidden")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.pinned", defaultValue: "Pinned")) {
                segmented(bind(\.pinned), [
                    (.list, String(localized: "sidebar.projects.customize.pinned.list", defaultValue: "List")),
                    (.tiles, String(localized: "sidebar.projects.customize.pinned.tiles", defaultValue: "Tiles")),
                ])
            }
            Divider()
            toggle(String(localized: "sidebar.projects.customize.search", defaultValue: "Search"), \.search)
            Divider()
            toggle(String(localized: "sidebar.projects.customize.cloudMachines", defaultValue: "Cloud machines"), \.cloudNav)
            Divider()
            toggle(String(localized: "sidebar.projects.customize.account", defaultValue: "Account bar"), \.footer)
        }
        .modifier(Box(title: String(localized: "sidebar.projects.customize.topAndBottom", defaultValue: "Top and bottom")))
    }

    @ViewBuilder private var rows: some View {
        Group {
            Row(String(localized: "sidebar.projects.customize.density", defaultValue: "Density")) {
                segmented(bind(\.density), [
                    (.compact, String(localized: "sidebar.projects.customize.density.compact", defaultValue: "Compact")),
                    (.regular, String(localized: "sidebar.projects.customize.density.regular", defaultValue: "Regular")),
                    (.roomy, String(localized: "sidebar.projects.customize.density.roomy", defaultValue: "Roomy")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.lines", defaultValue: "Lines")) {
                segmented(bind(\.lines), [
                    (.one, String(localized: "sidebar.projects.customize.lines.one", defaultValue: "One")),
                    (.two, String(localized: "sidebar.projects.customize.lines.two", defaultValue: "Two")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.rowStyle", defaultValue: "Style")) {
                segmented(bind(\.rows), [
                    (.rounded, String(localized: "sidebar.projects.customize.rows.rounded", defaultValue: "Rounded")),
                    (.flush, String(localized: "sidebar.projects.customize.rows.flush", defaultValue: "Flush")),
                ])
            }
        }
        .modifier(Box(title: nil))

        Group {
            Row(String(localized: "sidebar.projects.customize.titleShows", defaultValue: "Title")) {
                Picker("", selection: bind(\.title)) {
                    Text(String(localized: "sidebar.projects.customize.title.name", defaultValue: "Workspace name")).tag(Style.Title.name)
                    Text(String(localized: "sidebar.projects.customize.title.task", defaultValue: "Latest message")).tag(Style.Title.task)
                    Text(String(localized: "sidebar.projects.customize.title.directory", defaultValue: "Directory")).tag(Style.Title.directory)
                    Text(String(localized: "sidebar.projects.customize.title.branch", defaultValue: "Branch")).tag(Style.Title.branch)
                }
                .labelsHidden().fixedSize()
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.secondLine", defaultValue: "Second line")) {
                Picker("", selection: bind(\.detail)) {
                    Text(String(localized: "sidebar.projects.customize.detail.branch", defaultValue: "Branch")).tag(Style.Detail.branch)
                    Text(String(localized: "sidebar.projects.customize.detail.directory", defaultValue: "Directory")).tag(Style.Detail.directory)
                    Text(String(localized: "sidebar.projects.customize.detail.message", defaultValue: "Latest message")).tag(Style.Detail.message)
                    Text(String(localized: "sidebar.projects.customize.detail.machine", defaultValue: "Machine")).tag(Style.Detail.machine)
                }
                .labelsHidden().fixedSize()
            }
            .disabled(store.style.lines == .one)
            Divider()
            Row(String(localized: "sidebar.projects.customize.leading", defaultValue: "Leading")) {
                segmented(bind(\.leading), [
                    (.status, String(localized: "sidebar.projects.customize.leading.status", defaultValue: "Status")),
                    (.agent, String(localized: "sidebar.projects.customize.leading.agent", defaultValue: "Agent")),
                    (.none, String(localized: "sidebar.projects.customize.leading.none", defaultValue: "None")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.status", defaultValue: "Status")) {
                segmented(bind(\.status), [
                    (.marks, String(localized: "sidebar.projects.customize.status.marks", defaultValue: "Marks")),
                    (.words, String(localized: "sidebar.projects.customize.status.words", defaultValue: "Words")),
                    (.mono, String(localized: "sidebar.projects.customize.status.mono", defaultValue: "Mono")),
                ])
            }
        }
        .modifier(Box(title: String(localized: "sidebar.projects.customize.content", defaultValue: "Content")))

        Group {
            Row(String(localized: "sidebar.projects.customize.machine", defaultValue: "Machine")) {
                segmented(bind(\.machine), [
                    (.name, String(localized: "sidebar.projects.customize.machine.name", defaultValue: "Name")),
                    (.glyph, String(localized: "sidebar.projects.customize.machine.glyph", defaultValue: "Icon")),
                    (.hidden, String(localized: "sidebar.projects.customize.machine.hidden", defaultValue: "Hidden")),
                ])
            }
            Divider()
            toggle(String(localized: "sidebar.projects.customize.agents", defaultValue: "Agents"), \.agents)
                .disabled(store.style.leading == .agent)
            Divider()
            toggle(String(localized: "sidebar.projects.customize.time", defaultValue: "Time since last activity"), \.time)
            Divider()
            toggle(String(localized: "sidebar.projects.customize.diff", defaultValue: "Lines added and removed"), \.diff)
        }
        .modifier(Box(title: String(localized: "sidebar.projects.customize.trailing", defaultValue: "End of the row")))
    }

    @ViewBuilder private var look: some View {
        Group {
            Row(String(localized: "sidebar.projects.customize.accent", defaultValue: "Accent")) {
                HStack(spacing: 7) {
                    ForEach(Style.Accent.allCases, id: \.self) { accent in
                        let on = store.style.accent == accent
                        Circle()
                            .fill(accent == .system ? Color.accentColor : SidebarProjectsPalette(dark: true, accent: accent).accent)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.85 : 0), lineWidth: 1.5).padding(-3))
                            .contentShape(Circle())
                            .onTapGesture { store.style.accent = accent }
                            .help(accent.rawValue.capitalized)
                    }
                }
                .padding(.trailing, 3)
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.textSize", defaultValue: "Text size")) {
                segmented(bind(\.textSize), [
                    (.small, String(localized: "sidebar.projects.customize.text.small", defaultValue: "Small")),
                    (.medium, String(localized: "sidebar.projects.customize.text.medium", defaultValue: "Medium")),
                    (.large, String(localized: "sidebar.projects.customize.text.large", defaultValue: "Large")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.headers", defaultValue: "Section titles")) {
                segmented(bind(\.headers), [
                    (.caps, String(localized: "sidebar.projects.customize.headers.caps", defaultValue: "CAPS")),
                    (.title, String(localized: "sidebar.projects.customize.headers.title", defaultValue: "Title")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.projectIcon", defaultValue: "Project icon")) {
                segmented(bind(\.icon), [
                    (.letter, String(localized: "sidebar.projects.customize.icon.letter", defaultValue: "Letter")),
                    (.color, String(localized: "sidebar.projects.customize.icon.color", defaultValue: "Color")),
                    (.folder, String(localized: "sidebar.projects.customize.icon.folder", defaultValue: "Folder")),
                    (.none, String(localized: "sidebar.projects.customize.icon.none", defaultValue: "None")),
                ])
            }
            Divider()
            Row(String(localized: "sidebar.projects.customize.background", defaultValue: "Background")) {
                segmented(bind(\.backdrop), [
                    (.solid, String(localized: "sidebar.projects.customize.background.solid", defaultValue: "Solid")),
                    (.glass, String(localized: "sidebar.projects.customize.background.glass", defaultValue: "Glass")),
                ])
            }
        }
        .modifier(Box(title: nil))
    }

    // MARK: Helpers

    private func bind<Value>(_ path: WritableKeyPath<Style, Value>) -> Binding<Value> {
        Binding(get: { store.style[keyPath: path] }, set: { store.style[keyPath: path] = $0 })
    }

    private func segmented<Value: Hashable>(_ selection: Binding<Value>, _ options: [(Value, String)]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
    }

    private func toggle(_ title: String, _ path: WritableKeyPath<Style, Bool>) -> some View {
        Row(title) { Toggle("", isOn: bind(path)).toggleStyle(.switch).controlSize(.mini).labelsHidden() }
    }

    private func name(_ section: Style.Section) -> String {
        switch section {
        case .pinned:
            return String(localized: "sidebar.projects.customize.section.pinned", defaultValue: "Pinned")
        case .groups:
            switch store.style.groupBy {
            case .project: return String(localized: "sidebar.projects.customize.section.projects", defaultValue: "Projects")
            case .machine: return String(localized: "sidebar.projects.customize.section.byMachine", defaultValue: "By machine")
            case .status: return String(localized: "sidebar.projects.customize.section.byStatus", defaultValue: "By status")
            case .none: return String(localized: "sidebar.projects.customize.section.all", defaultValue: "Workspaces")
            }
        case .loose:
            return String(localized: "sidebar.projects.customize.section.loose", defaultValue: "Other workspaces")
        case .machines:
            return String(localized: "sidebar.projects.customize.section.machines", defaultValue: "Machines")
        }
    }

    // MARK: Pieces

    /// A label on the left, its control on the right.
    private struct Row<Control: View>: View {
        let title: String
        @ViewBuilder let control: () -> Control

        init(_ title: String, @ViewBuilder control: @escaping () -> Control) {
            self.title = title
            self.control = control
        }

        var body: some View {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12.5)).lineLimit(1).fixedSize().layoutPriority(1)
                Spacer(minLength: 8)
                control()
            }
            .padding(.horizontal, 10).frame(minHeight: 34)
        }
    }

    /// A grouped box like System Settings: optional title above, footnote below.
    private struct Box: ViewModifier {
        let title: String?
        var footer: String?

        func body(content: Content) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                if let title {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
                }
                VStack(spacing: 0) { content }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                if let footer {
                    Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 4)
                }
            }
            .padding(.top, 14)
        }
    }

    /// The sections, each with a visibility menu, reordered by dragging the handle.
    private struct SectionOrder: View {
        @ObservedObject var store: SidebarProjectsStyleStore
        let name: (Style.Section) -> String
        @State private var dragging: Style.Section?
        @State private var translation: CGFloat = 0
        private let rowHeight: CGFloat = 34

        var body: some View {
            let sections = store.style.sections
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    let lifted = dragging == section.id
                    VStack(spacing: 0) {
                        if index > 0 { Divider().opacity(lifted ? 0 : 1) }
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary)
                                .frame(width: 16, height: rowHeight)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 3, coordinateSpace: .global)
                                        .onChanged { value in
                                            if dragging == nil { dragging = section.id }
                                            translation = value.translation.height
                                        }
                                        .onEnded { _ in drop() }
                                )
                            Text(name(section.id)).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 8)
                            Picker("", selection: visibility(section.id)) {
                                Text(String(localized: "sidebar.projects.customize.always", defaultValue: "Always")).tag(Style.Visibility.always)
                                Text(String(localized: "sidebar.projects.customize.auto", defaultValue: "When not empty")).tag(Style.Visibility.auto)
                                // Only sections that can hide without losing a workspace offer it.
                                if section.id == .pinned {
                                    Text(String(localized: "sidebar.projects.customize.pinsInPlace", defaultValue: "Hidden, pins stay in place")).tag(Style.Visibility.hidden)
                                } else if Style.canHide(section.id) {
                                    Text(String(localized: "sidebar.projects.customize.hidden", defaultValue: "Hidden")).tag(Style.Visibility.hidden)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        .padding(.horizontal, 10).frame(height: rowHeight)
                        .opacity(section.id == .loose && store.style.groupBy != .project ? 0.45 : 1)
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)).opacity(lifted ? 1 : 0))
                    .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: lifted ? 8 : 0, y: lifted ? 3 : 0)
                    .offset(y: lifted ? translation : shift(index))
                    .zIndex(lifted ? 1 : 0)
                    .animation(lifted ? nil : .interpolatingSpring(mass: 1, stiffness: 300, damping: 30), value: target)
                }
            }
        }

        private var target: Int? {
            guard let dragging, let from = store.style.sections.firstIndex(where: { $0.id == dragging }) else { return nil }
            return max(0, min(store.style.sections.count - 1, from + Int((translation / rowHeight).rounded())))
        }

        private func shift(_ index: Int) -> CGFloat {
            guard let dragging, let target, let from = store.style.sections.firstIndex(where: { $0.id == dragging }) else { return 0 }
            if index > from, index <= target { return -rowHeight }
            if index < from, index >= target { return rowHeight }
            return 0
        }

        private func drop() {
            guard let dragging, let target, let from = store.style.sections.firstIndex(where: { $0.id == dragging }) else { return }
            withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.24)) {
                var sections = store.style.sections
                sections.insert(sections.remove(at: from), at: target)
                store.style.sections = sections
                self.dragging = nil
                translation = 0
            }
        }

        private func visibility(_ id: Style.Section) -> Binding<Style.Visibility> {
            Binding(
                get: { store.style.visibility(id) },
                set: { value in
                    guard let index = store.style.sections.firstIndex(where: { $0.id == id }) else { return }
                    store.style.sections[index].visibility = value
                }
            )
        }
    }

    /// Lays its children out left to right, wrapping to a new line when full.
    private struct FlowLayout: Layout {
        var spacing: CGFloat = 6

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
            let height = lines.last.map { $0.y + $0.height } ?? 0
            return CGSize(width: proposal.width ?? lines.map(\.width).max() ?? 0, height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            for line in arrange(width: bounds.width, subviews: subviews) {
                var x = bounds.minX
                for index in line.indices {
                    let size = subviews[index].sizeThatFits(.unspecified)
                    subviews[index].place(at: CGPoint(x: x, y: bounds.minY + line.y), proposal: ProposedViewSize(size))
                    x += size.width + spacing
                }
            }
        }

        private struct Line {
            var indices: [Int] = []
            var y: CGFloat = 0
            var width: CGFloat = 0
            var height: CGFloat = 0
        }

        private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
            var lines: [Line] = [Line()]
            for index in subviews.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                if !lines[lines.count - 1].indices.isEmpty, lines[lines.count - 1].width + spacing + size.width > width {
                    let last = lines[lines.count - 1]
                    lines.append(Line(y: last.y + last.height + spacing))
                }
                var line = lines[lines.count - 1]
                line.width += (line.indices.isEmpty ? 0 : spacing) + size.width
                line.height = max(line.height, size.height)
                line.indices.append(index)
                lines[lines.count - 1] = line
            }
            return lines
        }
    }
}
