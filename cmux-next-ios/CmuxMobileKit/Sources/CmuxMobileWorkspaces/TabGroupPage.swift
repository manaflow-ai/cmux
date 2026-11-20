#if os(iOS)
import CmuxMobileDesign
import CmuxMobileModel
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// A tab group's actions: the Mac's group chip menu (`TabGroupActionCatalog`), pushed from a
/// member's menu (Tab Group: <name>…; swipe back returns). Its tabs, then Appearance (Rename,
/// Color, Icon, Collapse), New Tab in Group, the moves, and Pin / Ungroup / Close. Each change is
/// the Mac's own request; the page shows what the Mac lists, and pops when the group is gone.
struct TabGroupPage: View {
    let source: WorkspaceTabsSource
    let groupID: String
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var name = ""
    @State private var choosingEmoji = false
    @State private var emojiText = ""
    @State private var choosingWorkspace = false

    var body: some View {
        let members = source.members(ofGroup: groupID)
        let group = members.first?.group
        content(members, group)
            .navigationTitle(group?.displayName ?? "Tab Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .background(theme.colors.bg.color.ignoresSafeArea())
            .overlay(alignment: .bottom) { PageToast(source: source) }
            // Ungrouped, closed or moved to another workspace on the Mac: nothing left to act on.
            .onChange(of: members.isEmpty) { _, empty in if empty { dismiss() } }
            .alert("Rename Tab Group", isPresented: $renaming) {
                TextField(group?.name.isEmpty == false ? group?.name ?? "Name" : "Name", text: $name)
                    // Names are code-like: no autocorrect, no capitals (full verify D5).
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("tabGroup.rename.field")
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await source.editGroup(.rename(name), group: groupID) } }
                    .keyboardShortcut(.defaultAction)
            }
            .alert("Set Tab Group Icon", isPresented: $choosingEmoji) {
                TextField("Emoji", text: $emojiText)
                Button("Cancel", role: .cancel) {}
                Button("Set") {
                    if let emoji = WorkspaceIcon.emoji(emojiText) { Task { await source.editGroup(.setIcon(emoji), group: groupID) } }
                }
                .disabled(WorkspaceIcon.emoji(emojiText) == nil)
                .keyboardShortcut(.defaultAction)
            } message: {
                Text("One emoji.")
            }
            .sheet(isPresented: $choosingWorkspace) {
                if let first = members.first {
                    WorkspacePicker(tab: first, workspaces: source.otherWorkspaces, title: "Move Tab Group to Workspace") { destination in
                        Task { await source.editGroup(.moveToWorkspace(destination), group: groupID) }
                    }
                    .presentationDetents([.medium, .large])
                }
            }
            // Close Tab Group's question when a tab in it is busy (the workspace's own is under this page).
            .alert(source.pendingClose?.title ?? "", isPresented: Binding(
                get: { source.pendingClose != nil },
                set: { shown in if !shown { source.resolvePendingClose(false) } }
            )) {
                Button("Close", role: .destructive) { source.resolvePendingClose(true) }
                Button("Cancel", role: .cancel) { source.resolvePendingClose(false) }
            } message: {
                Text(source.pendingClose?.message ?? "")
            }
            .accessibilityIdentifier("tabGroup.page")
    }

    @ViewBuilder
    private func content(_ members: [WorkspaceTab], _ group: WorkspaceTab.TabGroupRef?) -> some View {
        if let group {
            List {
                Section {
                    ForEach(members) { tab in
                        Button {
                            source.activate(tab.id)
                            source.route = nil
                            source.openedTab = tab.id
                        } label: {
                            Label {
                                Text(tab.title).foregroundStyle(theme.colors.label.color).lineLimit(1)
                            } icon: {
                                Image(systemName: tab.systemImage).foregroundStyle(theme.colors.label2.color)
                            }
                        }
                        .accessibilityIdentifier("tabGroup.tab.\(tab.id)")
                    }
                } header: {
                    HStack(spacing: 8) {
                        Circle().fill(TabGroupChip.color(group.color)).frame(width: 10, height: 10)
                        if let icon = group.icon { TabGroupIcon(icon: icon) }
                        Text(members.count == 1 ? "1 tab" : "\(members.count) tabs").textCase(nil)
                        if group.isCollapsed { Text("· Collapsed on \(source.macName)").textCase(nil) }
                    }
                }
                if source.canEditTabs {
                    appearance(group)
                    Section {
                        Button("New Tab in Group", systemImage: "plus.square.dashed") { Task { await source.newTabInGroup(groupID) } }
                    }
                    moves
                    Section {
                        if group.isSaved {
                            Button(TabGroupEdit.unsave.title, systemImage: "bookmark.slash") { Task { await source.editGroup(.unsave, group: groupID) } }
                        } else {
                            Button(TabGroupEdit.save.title, systemImage: "bookmark") { Task { await source.editGroup(.save, group: groupID) } }
                        }
                        Button(TabGroupEdit.ungroup.title, systemImage: "rectangle.stack.badge.minus") {
                            Task { await source.editGroup(.ungroup, group: groupID) }
                        }
                        Button(TabGroupEdit.close.title, systemImage: "xmark.rectangle.portrait", role: .destructive) {
                            Task { await source.editGroup(.close, group: groupID) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        } else {
            ContentUnavailableView("No Tab Group", systemImage: "rectangle.stack",
                                   description: Text("This group is no longer in the workspace on \(source.macName)."))
        }
    }

    @ViewBuilder
    private func appearance(_ group: WorkspaceTab.TabGroupRef) -> some View {
        Section("Appearance") {
            Button(TabGroupEdit.rename("").title, systemImage: "pencil") {
                // The current name, so Rename without typing keeps it.
                name = group.name
                renaming = true
            }
            Menu {
                ForEach(WorkspaceTab.TabGroupRef.colors, id: \.self) { color in
                    Button {
                        Task { await source.editGroup(.setColor(color), group: groupID) }
                    } label: {
                        if group.color == color {
                            Label(WorkspaceTab.TabGroupRef.colorTitle(color), systemImage: "checkmark")
                        } else {
                            Label { Text(WorkspaceTab.TabGroupRef.colorTitle(color)) } icon: { Self.swatch(color) }
                        }
                    }
                }
            } label: {
                LabeledContent {
                    Text(WorkspaceTab.TabGroupRef.colorTitle(group.color))
                } label: {
                    Label(TabGroupEdit.setColor("").title, systemImage: "paintpalette")
                }
            }
            .accessibilityIdentifier("tabGroup.color")
            Menu {
                ForEach(WorkspaceIcon.symbols, id: \.self) { symbol in
                    Button(symbol, systemImage: group.icon == symbol ? "checkmark" : symbol) {
                        Task { await source.editGroup(.setIcon(symbol), group: groupID) }
                    }
                }
                Button("Emoji…", systemImage: "face.smiling") {
                    emojiText = ""
                    choosingEmoji = true
                }
            } label: {
                Label(TabGroupEdit.setIcon("").title, systemImage: "face.smiling")
            }
            .accessibilityIdentifier("tabGroup.icon")
            if group.icon != nil {
                Button(TabGroupEdit.setIcon(nil).title, systemImage: "xmark.circle") {
                    Task { await source.editGroup(.setIcon(nil), group: groupID) }
                }
            }
            Button(TabGroupEdit.setCollapsed(!group.isCollapsed).title,
                   systemImage: group.isCollapsed ? "chevron.down" : "chevron.right") {
                Task { await source.editGroup(.setCollapsed(!group.isCollapsed), group: groupID) }
            }
        }
    }

    @ViewBuilder private var moves: some View {
        Section("Move") {
            if source.canMoveGroup(groupID, forward: false) {
                Button(TabGroupEdit.moveLeft.title, systemImage: "arrow.left") { Task { await source.editGroup(.moveLeft, group: groupID) } }
            }
            if source.canMoveGroup(groupID, forward: true) {
                Button(TabGroupEdit.moveRight.title, systemImage: "arrow.right") { Task { await source.editGroup(.moveRight, group: groupID) } }
            }
            Menu {
                ForEach(TabGroupEdge.allCases) { edge in
                    Button(edge.title, systemImage: edge.systemImage) { Task { await source.editGroup(.moveToSplit(edge), group: groupID) } }
                }
            } label: {
                Label(TabGroupEdit.moveToSplit(.right).title, systemImage: "rectangle.split.2x1")
            }
            .accessibilityIdentifier("tabGroup.moveToSplit")
            Button(TabGroupEdit.moveToColumn.title, systemImage: "rectangle.split.3x1") {
                Task { await source.editGroup(.moveToColumn, group: groupID) }
            }
            if !source.otherWorkspaces.isEmpty {
                Button(TabGroupEdit.moveToWorkspace("").title, systemImage: "arrow.right.square") { choosingWorkspace = true }
            }
            // Home's tabs stay in Home (the Mac's TabPromotion), as a tab's Move Tab to New Workspace.
            if source.workspace?.isHome != true {
                Button(TabGroupEdit.moveToNewWorkspace.title, systemImage: "rectangle.portrait.and.arrow.right") {
                    Task { await source.editGroup(.moveToNewWorkspace, group: groupID) }
                }
            }
        }
    }

    /// A menu icon: a filled circle in the group color, drawn as the workspace colors are (the
    /// Mac's tab groups and workspaces share one palette).
    static func swatch(_ color: String) -> Image {
        WorkspaceSwatch.image(WorkspaceColor(rawValue: color) ?? .grey)
    }
}
#endif
