#if os(iOS)
import SwiftUI

/// Design 3, Cards. Each workspace is a card with its latest message, like a
/// tab overview. Workspaces that need you ride a horizontal strip at the top;
/// the rest fill a two-column grid, newest first.
struct CardsDesign: View {
    let store: WorkspacesStore
    let open: (String) -> Void
    @State private var query = ""

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let searching = !query.isEmpty
        let all = store.grouping.search(store.workspaces, query: query, macs: store.macs)
        let needs = searching ? [] : all.filter { $0.status.needsUser }
        let rest = searching ? all : all.filter { !$0.status.needsUser }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HomeStatusLine(store: store).padding(.horizontal, 20)
                if !needs.isEmpty {
                    header("Needs you", count: needs.count)
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(needs) { item in
                                card(item, wide: true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                }
                if !rest.isEmpty {
                    header(searching ? "Results" : "All workspaces", count: rest.count)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(rest) { card($0, wide: false) }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .overlay { if all.isEmpty { HomeEmptyState(store: store, query: query) } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search workspaces and tabs")
        .safeAreaInset(edge: .bottom) { StartWorkspaceBar(store: store, open: open) }
        .modifier(TeamTitle(store: store))
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 20)
    }

    private func card(_ item: WorkspaceItem, wide: Bool) -> some View {
        Button { open(item.id) } label: { WorkspaceCard(item: item, store: store, wide: wide) }
            .buttonStyle(.plain)
            .workspaceActions(item, store: store, swipes: false)
    }
}

private struct WorkspaceCard: View {
    let item: WorkspaceItem
    let store: WorkspacesStore
    let wide: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                StatusMark(status: item.status)
            }
            Text(item.lastMessage)
                .font(.footnote).foregroundStyle(.secondary)
                .lineLimit(wide ? 2 : 4).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                ForEach(item.tabs.prefix(4)) { Image(systemName: $0.kind.systemImage) }
                if item.tabs.count > 4 { Text("+\(item.tabs.count - 4)") }
                Spacer(minLength: 4)
                UnreadBadge(count: item.unreadCount, blocking: item.status == .needsAttention)
                Text(store.grouping.shortAge(item.lastActivity))
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(store.isOffline(item) ? "Mac offline" : store.mac(item.macID)?.name ?? "")
                .font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(width: wide ? 260 : nil, height: wide ? 150 : 176, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))
        .overlay(alignment: .topLeading) {
            if item.isPinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).offset(x: -4, y: -4)
            }
        }
        .opacity(store.isOffline(item) ? 0.5 : 1)
        .contentShape(.rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }
}
#endif
