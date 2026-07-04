import AppKit
import CmuxIssueInbox
import CmuxWorkspaces
import SwiftUI

/// Top-level SwiftUI view for the Issue Inbox panel.
struct IssueInboxPanelView: View {
    @ObservedObject var panel: IssueInboxPanel
    @ObservedObject private var store: IssueInboxStore
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    @State private var didLoad = false
    @State private var searchText = ""
    @State private var statusFilter: IssueInboxStatusFilter = .open
    @State private var providerFilter: IssueProviderKind?

    init(
        panel: IssueInboxPanel,
        isFocused: Bool,
        onRequestPanelFocus: @escaping () -> Void
    ) {
        self.panel = panel
        self._store = ObservedObject(wrappedValue: panel.store)
        self.isFocused = isFocused
        self.onRequestPanelFocus = onRequestPanelFocus
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            guard !didLoad else { return }
            didLoad = true
            store.load()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: panel.displayIcon ?? "tray.full")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(String(localized: "issueInbox.title", defaultValue: "Issue Inbox"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                refreshIndicators
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(String(localized: "issueInbox.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!store.refreshing.isEmpty)
            }
            HStack(spacing: 10) {
                searchField
                statusPicker
                providerChips
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var refreshIndicators: some View {
        if !store.refreshing.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(store.refreshing).sorted(), id: \.self) { sourceID in
                    ProgressView()
                        .controlSize(.small)
                        .help(sourceDisplayName(sourceID))
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "issueInbox.search.placeholder", defaultValue: "Search issues"),
                text: $searchText
            )
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(minWidth: 180, maxWidth: 320)
    }

    private var statusPicker: some View {
        Picker("", selection: $statusFilter) {
            ForEach(IssueInboxStatusFilter.allCases, id: \.self) { filter in
                Text(statusTitle(filter)).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 230)
        .labelsHidden()
    }

    private var providerChips: some View {
        HStack(spacing: 6) {
            IssueInboxChipButton(
                title: String(localized: "issueInbox.provider.all", defaultValue: "All Providers"),
                isSelected: providerFilter == nil
            ) {
                providerFilter = nil
            }
            ForEach(providerKinds, id: \.self) { provider in
                IssueInboxChipButton(
                    title: providerTitle(provider),
                    isSelected: providerFilter == provider
                ) {
                    providerFilter = provider
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let filteredItems = IssueInboxFilter(
            status: statusFilter,
            provider: providerFilter,
            query: searchText
        ).apply(to: store.items)
        let rows = filteredItems.map { rowSnapshot(for: $0) }
        let cappedRows = Array(rows.prefix(500))
        if rows.isEmpty, store.sourceConfigs.isEmpty {
            IssueInboxEmptyStateView(configURL: store.configURL) {
                openConfigFile()
            }
        } else if rows.isEmpty {
            IssueInboxEmptyResultsView()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(errorSnapshots) { snapshot in
                        IssueInboxErrorBannerView(snapshot: snapshot)
                    }
                    ForEach(cappedRows) { snapshot in
                        IssueInboxRowView(
                            snapshot: snapshot,
                            actions: IssueInboxRowActions(
                                open: { openURL(snapshot.sourceURL) },
                                copyURL: { copyURL(snapshot.sourceURL) },
                                spawnWorkspace: { spawnWorkspace(issueID: snapshot.id) }
                            )
                        )
                    }
                    if rows.count > cappedRows.count {
                        IssueInboxFooterView(visibleCount: cappedRows.count, totalCount: rows.count)
                    }
                }
            }
        }
    }

    private var providerKinds: [IssueProviderKind] {
        let configured = store.sourceConfigs.map(\.type)
        let cached = store.items.map(\.provider)
        return Array(Set(configured + cached)).sorted { $0.rawValue < $1.rawValue }
    }

    private var errorSnapshots: [IssueInboxErrorBannerSnapshot] {
        store.sourceErrors
            .sorted { $0.key < $1.key }
            .map { sourceID, message in
                IssueInboxErrorBannerSnapshot(
                    id: sourceID,
                    sourceName: sourceDisplayName(sourceID),
                    message: message
                )
            }
    }

    private func rowSnapshot(for item: IssueInboxItem) -> IssueInboxRowSnapshot {
        let updatedText = IssueInboxRelativeDateFormatting.formatter.localizedString(for: item.updatedAt, relativeTo: Date())
        return IssueInboxRowSnapshot(
            id: item.id,
            sourceURL: item.sourceURL,
            providerIcon: providerIcon(item.provider),
            providerName: providerTitle(item.provider),
            number: item.number,
            title: item.title,
            repoOrProject: item.repoOrProject,
            labels: item.labels,
            assignees: item.assignees,
            updatedText: updatedText
        )
    }

    private func statusTitle(_ filter: IssueInboxStatusFilter) -> String {
        switch filter {
        case .open:
            return String(localized: "issueInbox.status.open", defaultValue: "Open")
        case .closed:
            return String(localized: "issueInbox.status.closed", defaultValue: "Closed")
        case .all:
            return String(localized: "issueInbox.status.all", defaultValue: "All")
        }
    }

    private func providerTitle(_ provider: IssueProviderKind) -> String {
        switch provider {
        case .github:
            return String(localized: "issueInbox.provider.github", defaultValue: "GitHub")
        case .linear:
            return String(localized: "issueInbox.provider.linear", defaultValue: "Linear")
        }
    }

    private func providerIcon(_ provider: IssueProviderKind) -> String {
        switch provider {
        case .github:
            return "circle.hexagongrid"
        case .linear:
            return "line.3.horizontal.decrease.circle"
        }
    }

    private func sourceDisplayName(_ sourceID: String) -> String {
        store.sourceConfigs.first { $0.sourceID == sourceID }?.displayName ?? sourceID
    }

    private func openURL(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    private func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func spawnWorkspace(issueID: String) {
        let result = TerminalController.shared.issueInboxSpawnWorkspace(
            issueID: issueID,
            cwd: nil,
            params: [:],
            forceFocus: true
        )
        if case .err = result {
            NSSound.beep()
        }
    }

    private func openConfigFile() {
        let url = store.configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                let stub = """
                {
                  "sources": [
                    { "type": "github", "repo": "manaflow-ai/cmux", "projectRoot": "~/fun/cmuxterm-hq/repo" },
                    { "type": "linear", "teamKey": "ENG", "projectRoot": "~/dev/thing", "apiKeyEnvVar": "LINEAR_API_KEY" }
                  ],
                  "autoRefreshSeconds": 0
                }
                """
                try stub.data(using: .utf8)?.write(to: url, options: .atomic)
            }
            PreferredEditorService(defaults: .standard).open(url)
        } catch {
            NSSound.beep()
        }
    }
}

@MainActor
private enum IssueInboxRelativeDateFormatting {
    static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct IssueInboxRowSnapshot: Identifiable, Equatable {
    let id: String
    let sourceURL: URL
    let providerIcon: String
    let providerName: String
    let number: String
    let title: String
    let repoOrProject: String
    let labels: [String]
    let assignees: [String]
    let updatedText: String
}

private struct IssueInboxRowActions {
    let open: () -> Void
    let copyURL: () -> Void
    let spawnWorkspace: () -> Void
}

private struct IssueInboxRowView: View {
    let snapshot: IssueInboxRowSnapshot
    let actions: IssueInboxRowActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: snapshot.providerIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .help(snapshot.providerName)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(snapshot.number)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(snapshot.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        Text(snapshot.repoOrProject)
                        Text(snapshot.updatedText)
                        if !snapshot.assignees.isEmpty {
                            Text(snapshot.assignees.joined(separator: ", "))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    if !snapshot.labels.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(snapshot.labels.prefix(6), id: \.self) { label in
                                Text(label)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    }
                }
                Spacer(minLength: 12)
                Button {
                    actions.spawnWorkspace()
                } label: {
                    Label(
                        String(localized: "issueInbox.spawnWorkspace", defaultValue: "Spawn Workspace"),
                        systemImage: "plus.square.on.square"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(String(localized: "issueInbox.spawnWorkspace", defaultValue: "Spawn Workspace"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                actions.open()
            }
            .contextMenu {
                Button(String(localized: "issueInbox.spawnWorkspace", defaultValue: "Spawn Workspace")) {
                    actions.spawnWorkspace()
                }
                Button(String(localized: "issueInbox.openInBrowser", defaultValue: "Open in Browser")) {
                    actions.open()
                }
                Button(String(localized: "issueInbox.copyURL", defaultValue: "Copy URL")) {
                    actions.copyURL()
                }
            }
            Divider()
        }
    }
}

private struct IssueInboxErrorBannerSnapshot: Identifiable, Equatable {
    let id: String
    let sourceName: String
    let message: String
}

private struct IssueInboxErrorBannerView: View {
    let snapshot: IssueInboxErrorBannerSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.sourceName)
                    .font(.system(size: 12, weight: .semibold))
                Text(snapshot.message)
                    .font(.system(size: 12))
                Text(String(localized: "issueInbox.error.stale", defaultValue: "Showing stale data for this source."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .systemOrange).opacity(0.10))
        Divider()
    }
}

private struct IssueInboxEmptyStateView: View {
    let configURL: URL
    let onOpenConfig: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "issueInbox.empty.title", defaultValue: "Configure Issue Inbox"))
                .font(.system(size: 18, weight: .semibold))
            Text(String(localized: "issueInbox.empty.body", defaultValue: "Add sources in ~/.config/cmux/issue-inbox.json."))
                .foregroundStyle(.secondary)
            Text(minimalExample)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button {
                onOpenConfig()
            } label: {
                Label(String(localized: "issueInbox.empty.openConfig", defaultValue: "Open Config"), systemImage: "doc.badge.gearshape")
            }
        }
        .padding(24)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
    }

    private var minimalExample: String {
        """
        {
          "sources": [
            { "type": "github", "repo": "manaflow-ai/cmux", "projectRoot": "~/fun/cmuxterm-hq/repo" },
            { "type": "linear", "teamKey": "ENG", "projectRoot": "~/dev/thing", "apiKeyEnvVar": "LINEAR_API_KEY" }
          ],
          "autoRefreshSeconds": 0
        }
        """
    }
}

private struct IssueInboxEmptyResultsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(String(localized: "issueInbox.emptyResults", defaultValue: "No matching issues"))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IssueInboxFooterView: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        Text(
            String(
                format: String(localized: "issueInbox.footer.showing", defaultValue: "Showing %lld of %lld"),
                Int64(visibleCount),
                Int64(totalCount)
            )
        )
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 12)
    }
}

private struct IssueInboxChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: isSelected ? .selectedContentBackgroundColor : .controlBackgroundColor).opacity(isSelected ? 0.18 : 1))
                )
        }
        .buttonStyle(.plain)
    }
}
