#if os(iOS)
import SwiftUI

/// The pencil: tap creates a workspace instantly on the last-used Mac; a
/// long press offers another Mac, a branch or a clone (Safari/Notes pattern).
struct NewWorkspaceButton: View {
    let store: WorkspacesStore
    let open: (String) -> Void

    var body: some View {
        Menu {
            Section("New workspace") {
                ForEach(store.macs.filter(\.isOnline)) { mac in
                    Button { open(store.create(on: mac.id).id) } label: {
                        Label("On \(mac.name)", systemImage: mac.id == store.newWorkspaceMacID ? "checkmark" : "desktopcomputer")
                    }
                }
            }
            Button("From a Branch…", systemImage: "arrow.triangle.branch") { open(store.create().id) }
            Button("Clone a Repository…", systemImage: "square.and.arrow.down") { open(store.create().id) }
        } label: {
            Image(systemName: "square.and.pencil")
        } primaryAction: {
            open(store.create().id)
        }
        .accessibilityLabel("New workspace")
    }
}

/// Team name with a chevron; the menu switches teams and invites.
struct TeamMenu<Label: View>: View {
    let store: WorkspacesStore
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Picker("Team", selection: Bindable(store).teamID) {
                ForEach(store.teams) { team in Text(team.name).tag(team.id) }
            }
            Divider()
            Button("Invite to Team", systemImage: "person.badge.plus") {}
        } label: {
            label()
        }
    }
}

/// Green and gray dots for the team's Macs, then "3 of 4 Macs online".
struct MacPresence: View {
    let macs: [WorkspaceMac]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(macs.prefix(5)) { mac in
                Circle().fill(mac.isOnline ? Color.green : Color(uiColor: .systemGray4)).frame(width: 6, height: 6)
            }
            Text("\(macs.filter(\.isOnline).count) of \(macs.count) Macs online")
                .padding(.leading, 3)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// Account, settings and sign out behind the avatar.
struct AccountMenu: View {
    var onExitDemo: (() -> Void)?

    var body: some View {
        Menu {
            Section("Aziz Albahar") {
                Button("Settings", systemImage: "gear") {}
                Button("Paired Macs", systemImage: "desktopcomputer") {}
            }
            if let onExitDemo {
                Button("Switch Design", systemImage: "square.grid.3x1.below.line.grid.1x2", action: onExitDemo)
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {}
        } label: {
            Text("AA")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .accessibilityLabel("Account")
    }
}

/// The press-and-hold menu and trailing swipe actions for one workspace.
struct WorkspaceActions: ViewModifier {
    let item: WorkspaceItem
    let store: WorkspacesStore
    var swipes = true
    @State private var renaming = false
    @State private var draftName = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") { store.togglePin(item.id) }
                Button("Rename", systemImage: "pencil") { draftName = item.name; renaming = true }
                if item.status != .done {
                    Button("Mark as Done", systemImage: "checkmark.circle") { store.markDone(item.id) }
                }
                Divider()
                Button("Copy Branch Name", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.branch }
                Button("Open on \(store.mac(item.macID)?.name ?? "Mac")", systemImage: "desktopcomputer") {}
                Divider()
                Button("Close Workspace", systemImage: "xmark", role: .destructive) { store.close(item.id) }
            }
            .modifier(SwipeIfNeeded(enabled: swipes, item: item, store: store))
            .alert("Rename Workspace", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { store.rename(item.id, to: draftName) }
            }
    }
}

/// Trailing swipes only: there is no leading action, so the edge swipe back
/// never competes with a row.
private struct SwipeIfNeeded: ViewModifier {
    let enabled: Bool
    let item: WorkspaceItem
    let store: WorkspacesStore

    func body(content: Content) -> some View {
        if enabled {
            content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Close", systemImage: "xmark", role: .destructive) { store.close(item.id) }
                Button(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin") { store.togglePin(item.id) }
                    .tint(.gray)
            }
        } else {
            content
        }
    }
}

extension View {
    func workspaceActions(_ item: WorkspaceItem, store: WorkspacesStore, swipes: Bool = true) -> some View {
        modifier(WorkspaceActions(item: item, store: store, swipes: swipes))
    }
}

/// Bottom prompt on the home screen: sending creates a workspace and hands
/// the text to Chief, like the Claude and ChatGPT home screens.
struct StartWorkspaceBar: View {
    let store: WorkspacesStore
    let open: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.workspacesTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            TextField("Start a workspace…", text: $text, axis: .vertical)
                .lineLimit(1 ... 4)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(send)
            Menu {
                Picker("Start on", selection: Bindable(store).newWorkspaceMacID) {
                    ForEach(store.macs.filter(\.isOnline)) { Text($0.name).tag($0.id) }
                }
            } label: {
                Text(store.mac(store.newWorkspaceMacID)?.name ?? "Mac")
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
            }
            .accessibilityLabel("Start on \(store.mac(store.newWorkspaceMacID)?.name ?? "Mac")")
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(Color(uiColor: .systemBackground))
                    .background(Circle().fill(isEmpty ? Color(uiColor: .systemGray3) : theme.label))
            }
            .disabled(isEmpty)
            .accessibilityLabel("Start workspace")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard !isEmpty else { return }
        let item = store.create(prompt: text)
        text = ""
        focused = false
        open(item.id)
    }
}
#endif
