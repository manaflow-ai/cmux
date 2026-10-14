#if os(iOS)
import SwiftUI

/// Design 2, Triage. Mail-style: filter chips, then Needs you, Running and
/// Everything else. Rows carry the latest message so you can triage without
/// opening anything; a waiting prompt can be answered from the row.
struct TriageDesign: View {
    let store: WorkspacesStore
    let open: (String) -> Void
    @State private var query = ""
    @State private var filter: WorkspaceFilter = .all

    var body: some View {
        let base = query.isEmpty ? store.workspaces.filter(filter.includes)
            : store.grouping.search(store.workspaces, query: query, macs: store.macs)
        let sections = store.grouping.byState(base)
        List {
            Section {
                HomeStatusLine(store: store)
                FilterChips(store: store, filter: $filter)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            .listRowSeparator(.hidden)
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        // Not a Button: the row holds its own Deny and Allow buttons.
                        TriageRow(item: item, store: store)
                            .onTapGesture { open(item.id) }
                            .accessibilityAddTraits(.isButton)
                            .workspaceActions(item, store: store)
                    }
                } header: {
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(section.items.count)").monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay { if sections.isEmpty { HomeEmptyState(store: store, query: query) } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search workspaces and tabs")
        .modifier(TeamTitle(store: store))
    }
}

private struct FilterChips: View {
    let store: WorkspacesStore
    @Binding var filter: WorkspaceFilter
    @Environment(\.workspacesTheme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                chip("All", .all)
                chip("Needs you", .needsYou, count: store.needsYouCount)
                chip("Running", .running, count: store.runningCount)
                ForEach(store.macs) { chip($0.name, .mac($0.id)) }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func chip(_ title: String, _ value: WorkspaceFilter, count: Int = 0) -> some View {
        let on = filter == value
        return Button { filter = value } label: {
            HStack(spacing: 4) {
                Text(title)
                if count > 0 { Text("\(count)").monospacedDigit().opacity(0.6) }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(on ? Color(uiColor: .systemBackground) : theme.label)
            .background(Capsule().fill(on ? theme.label : theme.fill))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct TriageRow: View {
    let item: WorkspaceItem
    let store: WorkspacesStore
    @Environment(\.workspacesTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusMark(status: item.status)
                Text(item.name).font(.body.weight(item.unreadCount > 0 ? .semibold : .regular))
                    .foregroundStyle(Color(uiColor: .label)).lineLimit(1)
                Spacer(minLength: 6)
                Text(store.grouping.shortAge(item.lastActivity)).font(.footnote).foregroundStyle(Color(uiColor: .secondaryLabel))
                UnreadBadge(count: item.unreadCount, blocking: item.status == .needsAttention)
            }
            Text(item.lastMessage).font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel)).lineLimit(2)
                .padding(.leading, 24)
            Text(store.isOffline(item) ? "Mac offline" : "\(item.branch) · \(store.mac(item.macID)?.name ?? "")")
                .font(.caption.monospaced()).foregroundStyle(Color(uiColor: .tertiaryLabel)).lineLimit(1)
                .padding(.leading, 24)
            if item.status == .needsAttention {
                HStack(spacing: 8) {
                    Button("Deny") { store.resolvePrompt(item.id, allow: false) }.buttonStyle(.bordered).tint(Color(uiColor: .label))
                    Button("Allow Once") { store.resolvePrompt(item.id, allow: true) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
                .padding(.leading, 24)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .opacity(store.isOffline(item) ? 0.5 : 1)
        .contentShape(.rect)
    }
}
#endif
