#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Panes: the workspace's panes as its Mac lays them out, pushed from the page menu (swipe back
/// returns). A picture of the shown screen's splits, then one section per pane with its tabs.
/// The pane's menu has the Mac's pane actions (Split, Zoom, Swap, Rename, Close); a tab's menu
/// moves it to a new split, a new column or another pane (and forks a chat beside it); the
/// toolbar adds panes and has Undo Layout Change and Equalize Splits. Everything is what the
/// Mac lists: an action shows here once the Mac made it.
struct PanesScreen: View {
    let source: WorkspaceTabsSource
    @Environment(\.dismiss) private var dismiss
    @State private var paneName = ""

    var body: some View {
        content
            .navigationTitle("Panes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { toolbar }
            .background(theme.colors.bg.color.ignoresSafeArea())
            .overlay(alignment: .bottom) { toast }
            .alert("Rename Pane", isPresented: Binding(
                get: { source.renamingPane != nil },
                set: { shown in if !shown { source.renamingPane = nil } }
            ), presenting: source.renamingPane) { pane in
                TextField(source.title(of: pane), text: $paneName)
                    // Names are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("panes.rename.field")
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await source.renamePane(pane, to: paneName) } }
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("Leave the name empty to clear it.")
            }
            .alert("Undo Layout Change?", isPresented: Binding(
                get: { source.pendingLayoutUndo != nil },
                set: { shown in if !shown { source.pendingLayoutUndo = nil } }
            ), presenting: source.pendingLayoutUndo) { pending in
                Button("Undo", role: .destructive) { Task { await source.undoLayout(confirming: pending) } }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.closing == 1 ? "This closes 1 pane on the Mac." : "This closes \(pending.closing) panes on the Mac.")
            }
            // Close Pane's question when a tab in it is busy (the workspace's own alert is hidden under this page).
            .alert(source.pendingClose?.title ?? "", isPresented: Binding(
                get: { source.pendingClose != nil },
                set: { shown in if !shown { source.resolvePendingClose(false) } }
            )) {
                Button("Close", role: .destructive) { source.resolvePendingClose(true) }
                Button("Cancel", role: .cancel) { source.resolvePendingClose(false) }
            } message: {
                Text(source.pendingClose?.message ?? "")
            }
            .accessibilityIdentifier("panes.screen")
    }

    @ViewBuilder private var content: some View {
        if let layout = source.layout, !layout.panes.isEmpty {
            List {
                if let screen = layout.activeScreen, let root = screen.root, screen.panes.count > 1 {
                    Section {
                        PaneLayoutDiagram(root: root, screen: screen, layout: layout)
                            .frame(height: 150)
                            .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    }
                }
                ForEach(layout.screens) { screen in
                    ForEach(screen.panes) { pane in
                        Section {
                            let tabs = source.tabs(of: pane)
                            if tabs.isEmpty {
                                Text("No tabs the iPhone shows").foregroundStyle(theme.colors.label2.color)
                            }
                            ForEach(tabs) { tab in row(tab, in: pane, layout: layout) }
                        } header: {
                            header(pane, screen: screen, layout: layout)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No Panes Yet", systemImage: "rectangle.split.2x1",
                                   description: Text("\(source.macName) hasn't listed this workspace's panes."))
        }
    }

    // MARK: Pane header and its menu

    private func header(_ pane: WorkspaceLayout.Pane, screen: WorkspaceLayout.Screen, layout: WorkspaceLayout) -> some View {
        HStack(spacing: 6) {
            Text(layout.screens.count > 1 && !screen.name.isEmpty ? "\(screen.name) · \(source.title(of: pane))" : source.title(of: pane))
                .textCase(nil)
            if pane.isZoomed { badge("Zoomed") }
            if pane.isFocused { badge("Focused") }
            Spacer()
            if source.canEditPanes {
                Menu {
                    paneMenu(pane, screen: screen, layout: layout)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 32)
                        .contentShape(.rect)
                }
                .accessibilityLabel("\(source.title(of: pane)) Actions")
                .accessibilityIdentifier("panes.menu.\(pane.id)")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .textCase(nil)
            .font(theme.type.meta.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(theme.colors.label.color.opacity(0.08), in: .capsule)
    }

    @ViewBuilder private func paneMenu(_ pane: WorkspaceLayout.Pane, screen: WorkspaceLayout.Screen, layout: WorkspaceLayout) -> some View {
        Section {
            ForEach(PaneSplit.allCases, id: \.self) { direction in
                Button(direction.title, systemImage: direction.systemImage) { Task { await source.split(pane, direction) } }
            }
        }
        Section {
            if screen.panes.count > 1 {
                Button(pane.isZoomed ? "Unzoom Pane" : "Zoom Pane",
                       systemImage: pane.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                    Task { await source.toggleZoom(pane) }
                }
            }
            ForEach(layout.swapDirections(of: pane.id), id: \.self) { direction in
                Button(direction.title, systemImage: direction.systemImage) { Task { await source.swap(pane, direction) } }
            }
            Button("Rename Pane…", systemImage: "pencil") {
                // The current name, so Rename without typing keeps it.
                paneName = pane.name
                source.renamingPane = pane
            }
        }
        if screen.panes.count > 1 {
            Section {
                Button("Close Pane", systemImage: "xmark.rectangle", role: .destructive) { Task { await source.closePane(pane) } }
            }
        }
    }

    // MARK: Tab rows and their menu

    private func row(_ tab: WorkspaceTab, in pane: WorkspaceLayout.Pane, layout: WorkspaceLayout) -> some View {
        Button {
            source.activate(tab.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: Self.symbol(tab.kind))
                    .frame(width: 24)
                    .foregroundStyle(theme.colors.label2.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.title).foregroundStyle(theme.colors.label.color).lineLimit(1)
                    if let subtitle = tab.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(theme.type.meta).foregroundStyle(theme.colors.label2.color).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer()
                if pane.activeTabID == tab.id {
                    Text("Shown").font(theme.type.meta).foregroundStyle(theme.colors.label2.color)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("panes.tab.\(tab.id)")
        .accessibilityHint("Opens the tab")
        .contextMenu { tabMenu(tab, in: pane, layout: layout) }
    }

    @ViewBuilder private func tabMenu(_ tab: WorkspaceTab, in pane: WorkspaceLayout.Pane, layout: WorkspaceLayout) -> some View {
        Button("Open Tab", systemImage: "arrow.up.forward.square") {
            source.activate(tab.id)
            dismiss()
        }
        if source.canEditPanes {
            Section {
                // The daemon splits a tab out only of a pane that keeps another tab (one the iPhone doesn't list counts too).
                if pane.tabCount > 1 {
                    Menu("Move Tab to New Split", systemImage: "rectangle.split.2x1") {
                        ForEach(TabSplitEdge.allCases, id: \.self) { edge in
                            Button(edge.title, systemImage: edge.systemImage) { Task { await source.moveTab(tab, toNewSplit: edge) } }
                        }
                    }
                }
                Button("Move Tab to New Column", systemImage: "rectangle.split.3x1") { Task { await source.moveTabToNewColumn(tab) } }
                let others = layout.otherPanes(than: pane.id)
                if !others.isEmpty {
                    Menu("Move Tab to Pane", systemImage: "arrow.right.square") {
                        ForEach(others) { other in
                            Button(source.title(of: other)) { Task { await source.moveTab(tab, to: other) } }
                        }
                    }
                }
            }
            if tab.kind == .agent {
                Menu("Fork Conversation", systemImage: "arrow.triangle.branch") {
                    ForEach(ChatForkDestination.allCases) { destination in
                        Button(destination.title) { Task { await source.fork(tab.id, to: destination) } }
                    }
                }
            }
        }
        Button("Close Tab", systemImage: "xmark", role: .destructive) { Task { _ = await source.close(tab.id) } }
    }

    static func symbol(_ kind: WorkspaceTab.Kind) -> String {
        switch kind {
        case .terminal: "terminal"
        case .browser: "globe"
        case .agent: "bubble.left.and.text.bubble.right"
        case .simulator: "iphone"
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if source.canEditPanes, let layout = source.layout, let screen = layout.activeScreen,
           let pane = screen.panes.first(where: \.isFocused) ?? screen.panes.first {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Undo Layout Change", systemImage: "arrow.uturn.backward.square") { Task { await source.undoLayout() } }
                    if screen.hasSplits {
                        Button("Equalize Splits", systemImage: "equal.square") { Task { await source.equalizeSplits() } }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Layout")
                .accessibilityIdentifier("panes.layout")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section(source.title(of: pane)) {
                        ForEach(PaneSplit.allCases, id: \.self) { direction in
                            Button(direction.title, systemImage: direction.systemImage) { Task { await source.split(pane, direction) } }
                        }
                    }
                    Section {
                        Button("New Pane", systemImage: "rectangle.badge.plus") { Task { await source.newPane(from: pane, column: false) } }
                        Button("New Column", systemImage: "rectangle.split.3x1") { Task { await source.newPane(from: pane, column: true) } }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Pane")
                .accessibilityIdentifier("panes.add")
            }
        }
    }

    // MARK: Toast

    @ViewBuilder private var toast: some View {
        Group {
            if let title = source.pendingTabTitle {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(WorkspaceScreen.openingText(title))
                }
            } else if let text = source.toastText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(text).fixedSize(horizontal: false, vertical: true)
                }
                .onTapGesture { source.clearNotice() }
            }
        }
        .font(theme.type.meta.weight(.semibold))
        .foregroundStyle(theme.colors.label.color)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("panes.toast")
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .opacity(source.pendingTabTitle == nil && source.toastText == nil ? 0 : 1)
        .allowsHitTesting(source.toastText != nil)
    }
}

/// A small picture of the shown screen's splits at their Mac ratios: each pane a box with its
/// name, the focused one outlined, a zoomed one marked. Only a picture: the sections below act.
struct PaneLayoutDiagram: View {
    let root: WorkspaceLayout.Node
    let screen: WorkspaceLayout.Screen
    let layout: WorkspaceLayout

    var body: some View {
        GeometryReader { proxy in
            node(root, size: proxy.size)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("panes.diagram")
    }

    private var summary: String {
        let names = screen.panes.map { pane in
            layout.title(of: pane) + (pane.isFocused ? ", focused" : "") + (pane.isZoomed ? ", zoomed" : "")
        }
        return "Layout of \(screen.panes.count) panes: " + names.joined(separator: "; ")
    }

    private func node(_ node: WorkspaceLayout.Node, size: CGSize) -> AnyView {
        switch node {
        case .pane(let id):
            return AnyView(cell(id).frame(width: size.width, height: size.height))
        case .stack(_, let expanded):
            return AnyView(cell(expanded).frame(width: size.width, height: size.height))
        case .split(_, let axis, let ratio, let first, let second):
            let gap: CGFloat = 4
            let share = min(max(ratio, 0.05), 0.95)
            if axis == .horizontal {
                let a = max(0, (size.width - gap) * share)
                let b = max(0, size.width - gap - a)
                return AnyView(HStack(spacing: gap) {
                    self.node(first, size: CGSize(width: a, height: size.height))
                    self.node(second, size: CGSize(width: b, height: size.height))
                })
            }
            let a = max(0, (size.height - gap) * share)
            let b = max(0, size.height - gap - a)
            return AnyView(VStack(spacing: gap) {
                self.node(first, size: CGSize(width: size.width, height: a))
                self.node(second, size: CGSize(width: size.width, height: b))
            })
        }
    }

    private func cell(_ id: Int) -> some View {
        let pane = layout.pane(id)
        let focused = pane?.isFocused == true
        return RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(focused ? 0.16 : 0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(focused ? 0.7 : 0.15), lineWidth: focused ? 2 : 1)
            }
            .overlay {
                VStack(spacing: 2) {
                    Text(pane.map(layout.title(of:)) ?? "Pane").lineLimit(1)
                    if pane?.isZoomed == true { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
                .font(CmuxMobileTheme.standard.type.meta)
                .minimumScaleFactor(0.6)
                .padding(4)
            }
    }
}
#endif
