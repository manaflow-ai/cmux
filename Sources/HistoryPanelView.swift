import SwiftUI

struct HistoryPanelView: View {
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var closedItemHistoryStore = ClosedItemHistoryStore.shared
    @ObservedObject private var focusHistoryStore = FocusHistoryStore.shared
    @State private var selectedTab: HistoryTab = .focus

    enum HistoryTab: String, CaseIterable {
        case focus
        case closed

        var label: String {
            switch self {
            case .focus:
                return String(localized: "historyPane.tab.focus", defaultValue: "Focus History")
            case .closed:
                return String(localized: "historyPane.tab.closed", defaultValue: "Recently Closed")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(HistoryTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.label)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .focus:
            focusHistoryList
        case .closed:
            closedHistoryList
        }
    }

    private var focusHistoryList: some View {
        let snapshot = tabManager.focusHistoryMenuSnapshot(direction: .back)
        return Group {
            if snapshot.items.isEmpty {
                emptyState(message: String(localized: "historyPane.focus.empty", defaultValue: "No focus history yet"))
            } else {
                List {
                    ForEach(snapshot.items, id: \.historyIndex) { item in
                        focusHistoryRow(item: item)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func focusHistoryRow(item: FocusHistoryMenuItem) -> some View {
        Button(action: {
            _ = tabManager.navigateToFocusHistoryMenuItem(item)
        }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(FocusHistoryMenuFormatter.title(for: item))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(FocusHistoryMenuFormatter.subtitle(for: item))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .disabled(!item.isNavigable)
        .opacity(item.isNavigable ? 1.0 : 0.5)
    }

    private var closedHistoryList: some View {
        let snapshot = closedItemHistoryStore.menuSnapshot()
        return Group {
            if snapshot.items.isEmpty {
                emptyState(message: String(localized: "historyPane.closed.empty", defaultValue: "No recently closed items"))
            } else {
                List {
                    ForEach(snapshot.items) { item in
                        closedHistoryRow(item: item)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func closedHistoryRow(item: ClosedItemHistoryMenuItem) -> some View {
        Button(action: {
            AppDelegate.shared?.reopenClosedHistoryItem(id: item.id, preferredTabManager: tabManager)
        }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(item.menuSubtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func emptyState(message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}
