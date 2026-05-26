import AppKit
import SwiftUI

enum HistoryDayGrouping {
    static func matches(query: String, fields: [String]) -> Bool {
        let terms = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return true }

        let haystack = fields.joined(separator: " ")
        return terms.allSatisfy { term in
            haystack.localizedCaseInsensitiveContains(term)
        }
    }

    static func dayTitle(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "historyPane.day.today", defaultValue: "Today")
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "historyPane.day.yesterday", defaultValue: "Yesterday")
        }

        return Self.dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

struct HistoryPanelView: View {
    @ObservedObject private var closedStore = ClosedItemHistoryStore.shared
    @EnvironmentObject private var tabManager: TabManager

    let focusSearchToken: Int
    let onFocus: () -> Void
    let onOpenClosedItem: (UUID) -> Bool
    let onOpenFocusedItem: (FocusHistoryMenuItem) -> Bool
    let onClearClosedItems: () -> Void

    @State private var query = ""
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        let closedSnapshot = closedStore.menuSnapshot()
        let focusedBackSnapshot = tabManager.focusHistoryMenuSnapshot(direction: .back)
        let focusedForwardSnapshot = tabManager.focusHistoryMenuSnapshot(direction: .forward)
        let _ = closedStore.revision
        let _ = tabManager.focusHistoryRevision
        let closedGroups = groupedRows(
            closedSnapshot.items.map(Self.closedRow),
            query: query
        )
        let focusedGroups = groupedRows(
            (focusedBackSnapshot.items + focusedForwardSnapshot.items).map(Self.focusedRow),
            query: query
        )
        let hasAnyRows = !closedSnapshot.items.isEmpty ||
            !focusedBackSnapshot.items.isEmpty ||
            !focusedForwardSnapshot.items.isEmpty
        let hasVisibleRows = !closedGroups.isEmpty || !focusedGroups.isEmpty

        VStack(spacing: 0) {
            header(
                hasClosedItems: !closedSnapshot.items.isEmpty
            )

            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if !hasAnyRows {
                emptyState(String(localized: "historyPane.empty", defaultValue: "No history yet"))
            } else if !hasVisibleRows {
                emptyState(String(localized: "historyPane.noResults", defaultValue: "No matching history"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if !closedGroups.isEmpty {
                            historySection(
                                title: String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"),
                                groups: closedGroups
                            )
                        }

                        if !focusedGroups.isEmpty {
                            historySection(
                                title: String(localized: "menu.history.recentlyFocused", defaultValue: "Recently Focused"),
                                groups: focusedGroups
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onFocus)
        .onAppear {
            guard focusSearchToken > 0 else { return }
            focusSearchField()
        }
        .onChange(of: focusSearchToken) { _, _ in
            focusSearchField()
        }
    }

    private func header(hasClosedItems: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text(String(localized: "menu.history.title", defaultValue: "History"))
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 8)

            Button(String(localized: "historyPane.clearClosed", defaultValue: "Clear Closed")) {
                onClearClosedItems()
            }
            .disabled(!hasClosedItems)
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .help(String(localized: "historyPane.clearClosed.help", defaultValue: "Clear recently closed history"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
        .accessibilityIdentifier("HistoryPane.Header")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(String(localized: "historyPane.search.placeholder", defaultValue: "Search history"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFieldFocused)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "historyPane.search.clear", defaultValue: "Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .padding(.top, 10)
        .accessibilityIdentifier("HistoryPane.SearchField")
    }

    private func focusSearchField() {
        Task { @MainActor in
            isSearchFieldFocused = true
        }
    }

    private func emptyState(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(20)
            .accessibilityIdentifier("HistoryPane.EmptyState")
    }

    private func historySection(title: String, groups: [HistoryPaneDayGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 2)

            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                        .padding(.top, 2)

                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(group.rows) { row in
                            HistoryPaneRowView(row: row) {
                                switch row.kind {
                                case .closed(let id):
                                    if !onOpenClosedItem(id) {
                                        NSSound.beep()
                                    }
                                case .focused(let item):
                                    if !onOpenFocusedItem(item) {
                                        NSSound.beep()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupedRows(_ rows: [HistoryPaneRow], query: String) -> [HistoryPaneDayGroup] {
        let calendar = Calendar.current
        let filteredRows = rows
            .filter { row in
                HistoryDayGrouping.matches(
                    query: query,
                    fields: [row.title, row.subtitle, row.detail, row.badge]
                )
            }
            .sorted { lhs, rhs in lhs.timestamp > rhs.timestamp }

        let grouped = Dictionary(grouping: filteredRows) { row in
            calendar.startOfDay(for: row.timestamp)
        }

        return grouped.keys
            .sorted(by: >)
            .compactMap { day in
                guard let rows = grouped[day], !rows.isEmpty else { return nil }
                return HistoryPaneDayGroup(
                    day: day,
                    title: HistoryDayGrouping.dayTitle(for: day, calendar: calendar),
                    rows: rows
                )
            }
    }

    private static func closedRow(_ item: ClosedItemHistoryMenuItem) -> HistoryPaneRow {
        let time = item.closedAt.formatted(date: .omitted, time: .shortened)
        return HistoryPaneRow(
            id: "closed-\(item.id.uuidString)",
            title: item.title,
            subtitle: item.detail,
            detail: String(
                format: String(localized: "historyPane.closedAtFormat", defaultValue: "Closed %@"),
                time
            ),
            badge: String(localized: "menu.history.recentlyClosed", defaultValue: "Recently Closed"),
            timestamp: item.closedAt,
            kind: .closed(item.id)
        )
    }

    private static func focusedRow(_ item: FocusHistoryMenuItem) -> HistoryPaneRow {
        let time = item.focusedAt.formatted(date: .omitted, time: .shortened)
        let badge: String
        switch item.position {
        case .older:
            badge = String(localized: "menu.history.focusBack", defaultValue: "Focus Back")
        case .newer:
            badge = String(localized: "menu.history.focusForward", defaultValue: "Focus Forward")
        }

        return HistoryPaneRow(
            id: "focused-\(item.position)-\(item.historyIndex)",
            title: item.workspaceTitle,
            subtitle: item.panelTitle ?? badge,
            detail: String(
                format: String(localized: "historyPane.focusedAtFormat", defaultValue: "Focused %@"),
                time
            ),
            badge: badge,
            timestamp: item.focusedAt,
            kind: .focused(item)
        )
    }
}

private struct HistoryPaneDayGroup: Identifiable {
    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    let day: Date
    let title: String
    let rows: [HistoryPaneRow]
}

private struct HistoryPaneRow: Identifiable {
    enum Kind {
        case closed(UUID)
        case focused(FocusHistoryMenuItem)
    }

    let id: String
    let title: String
    let subtitle: String
    let detail: String
    let badge: String
    let timestamp: Date
    let kind: Kind
}

private struct HistoryPaneRowView: View {
    let row: HistoryPaneRow
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(row.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(row.badge)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(row.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryPaneRowButtonStyle(isHovered: isHovered))
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("HistoryPane.Row.\(row.id)")
    }
}

private struct HistoryPaneRowButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        Color.primary.opacity(
                            configuration.isPressed ? 0.11 : (isHovered ? 0.07 : 0)
                        )
                    )
            )
    }
}
