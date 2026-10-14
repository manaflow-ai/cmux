#if os(iOS)
import SwiftUI

/// Design 1, Recents. The Claude/ChatGPT history list promoted to the home
/// screen: Pinned, then Today, Yesterday, Previous 7 days. Two-line rows; the
/// prompt box at the bottom starts a new workspace.
struct RecentsDesign: View {
    let store: WorkspacesStore
    let open: (String) -> Void
    @State private var query = ""

    var body: some View {
        let sections = query.isEmpty
            ? store.grouping.byDate(store.workspaces)
            : [WorkspaceSection(kind: .other, title: "Results",
                                items: store.grouping.search(store.workspaces, query: query, macs: store.macs))].filter { !$0.items.isEmpty }
        List {
            Section { HomeStatusLine(store: store).listRowSeparator(.hidden) }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 4, trailing: 20))
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Button { open(item.id) } label: { RecentsRow(item: item, store: store) }
                            .workspaceActions(item, store: store)
                    }
                }
                .listSectionSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if sections.isEmpty { HomeEmptyState(store: store, query: query) } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search workspaces and tabs")
        .safeAreaInset(edge: .bottom) { StartWorkspaceBar(store: store, open: open) }
        .modifier(TeamTitle(store: store))
    }
}

private struct RecentsRow: View {
    let item: WorkspaceItem
    let store: WorkspacesStore

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body).foregroundStyle(.primary).lineLimit(1)
                HStack(spacing: 4) {
                    if item.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                    Text(store.meta(item)).lineLimit(1)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            UnreadBadge(count: item.unreadCount, blocking: item.status == .needsAttention)
            StatusMark(status: item.status)
        }
        .padding(.vertical, 2)
        .opacity(store.isOffline(item) ? 0.5 : 1)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}
#endif
