import AppKit
import CmuxArtifacts
import CmuxAppKitSupportUI
import SwiftUI

/// Workspace-owned Artifacts view with an explicit workspace/global scope switch.
struct ArtifactsPaneContent: View {
    let workspace: Workspace
    let artifactsState: WorkspaceArtifactsState
    let titleFetcher: LinkTitleFetcher
    let isFocused: Bool

    @State private var query = ""
    @State private var scope: ArtifactPaneScope = .workspace
    @State private var kindFilter: ArtifactPaneKindFilter = .all
    @State private var selectedHost: String?
    @State private var selectedSource: ArtifactSource?
    @State private var rows: [ArtifactPaneRowSnapshot] = []
    @State private var hostOptions: [String] = []
    @State private var sourceOptions: [ArtifactSource] = []
    @State private var dayBuckets: [ArtifactPaneDayBucket] = []
    @State private var selectedID: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            searchField
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            filterBar
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider()
            if rows.isEmpty {
                emptyState
            } else {
                artifactList
            }
        }
        .accessibilityIdentifier("ArtifactsPane")
        .task(id: queryKey) {
            await reload()
        }
        .task(id: "titles-\(queryKey)-\(artifactsState.structuralRevision)") {
            await fetchVisibleTitles()
        }
        .onAppear {
            if isFocused { listFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { listFocused = true }
        }
    }

    private var queryKey: String {
        "\(scope.rawValue)|\(kindFilter.rawValue)|\(selectedHost ?? "")|\(selectedSource?.rawValue ?? "")|\(query)|\(artifactsState.structuralRevision)"
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "artifactsPane.title", defaultValue: "Artifacts"))
                    .font(.system(size: 15, weight: .semibold))
                Text(countText(rows.count))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: presentAddPanel) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .clipShape(Circle())
            .safeHelp(String(localized: "artifactsPane.action.add", defaultValue: "Add Artifact"))
            .accessibilityLabel(String(localized: "artifactsPane.action.add", defaultValue: "Add Artifact"))
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                String(localized: "artifactsPane.search.placeholder", defaultValue: "Search artifacts"),
                text: $query
            )
            .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "artifactsPane.search.clear", defaultValue: "Clear search"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                scopeMenu
                kindMenu
                hostMenu
                sourceMenu
            }
        }
        .scrollClipDisabled()
    }

    private var scopeMenu: some View {
        Picker(
            String(localized: "artifactsPane.scope.label", defaultValue: "Scope"),
            selection: $scope
        ) {
            Text(String(localized: "artifactsPane.scope.workspace", defaultValue: "This Workspace"))
                .tag(ArtifactPaneScope.workspace)
            Text(String(localized: "artifactsPane.scope.global", defaultValue: "All Workspaces"))
                .tag(ArtifactPaneScope.global)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .background(.quaternary.opacity(0.45), in: Capsule())
    }

    private var kindMenu: some View {
        Menu {
            ForEach(ArtifactPaneKindFilter.allCases, id: \.self) { filter in
                Button(filter.label) { kindFilter = filter }
            }
        } label: {
            filterChip(kindFilter.label, systemImage: "square.grid.2x2")
        }
    }

    private var hostMenu: some View {
        Menu {
            Button(String(localized: "artifactsPane.host.all", defaultValue: "All Hosts")) {
                selectedHost = nil
            }
            ForEach(hostOptions, id: \.self) { host in
                Button(host) { selectedHost = host }
            }
        } label: {
            filterChip(selectedHost ?? String(localized: "artifactsPane.host.all", defaultValue: "All Hosts"), systemImage: "server.rack")
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button(String(localized: "artifactsPane.source.all", defaultValue: "All Sources")) {
                selectedSource = nil
            }
            ForEach(sourceOptions, id: \.self) { source in
                Button(sourceLabel(source)) { selectedSource = source }
            }
        } label: {
            filterChip(selectedSource.map(sourceLabel) ?? String(localized: "artifactsPane.source.all", defaultValue: "All Sources"), systemImage: "tray.full")
        }
    }

    private func filterChip(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.45), in: Capsule())
    }

    @ViewBuilder
    private var artifactList: some View {
        let actions = ArtifactPaneRowActions(
            open: { ArtifactActionRouter().open($0.record, from: workspace) },
            openBuiltIn: { ArtifactActionRouter().openBuiltIn($0.record, from: workspace) },
            openExternal: { ArtifactActionRouter().openExternal($0.record) },
            copy: { copy($0.record.copyValue) },
            reveal: { ArtifactActionRouter().reveal($0.record, from: workspace) },
            remove: { remove($0.record) },
            clearAll: { artifactsState.clearAll() },
            dragProvider: { ArtifactActionRouter().dragProvider($0.record, from: workspace) }
        )
        List(selection: $selectedID) {
                ForEach(dayBuckets) { bucket in
                Section {
                    ForEach(bucket.rows) { row in
                        ArtifactPaneRow(snapshot: row, actions: actions)
                            .tag(row.id)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    Text(bucket.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        // This view already lives inside cmux's styled right-sidebar shell.
        // A nested `.sidebar` list adds its own opaque material and produces
        // the background seam visible in the Artifacts mode; Vault uses a
        // plain transparent table for the same reason.
        .listStyle(.plain)
        // The right-sidebar shell (and standalone Artifacts pane) owns the
        // resolved backdrop. Keep AppKit's List scroll view transparent so it
        // does not introduce a second opaque system-window background.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .modifier(ClearScrollBackground())
        .focused($listFocused)
        .onKeyPress { handleKeyPress($0) }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "shippingbox" : "magnifyingglass")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(.tertiary)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "artifactsPane.empty.title", defaultValue: "No Artifacts Yet")
                : String(localized: "artifactsPane.empty.searchTitle", defaultValue: "No Matches"))
                .font(.headline)
            Text(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "artifactsPane.empty.message", defaultValue: "URLs, files, HTML, and saved workspace content will appear here.")
                : String(localized: "artifactsPane.empty.searchMessage", defaultValue: "Try another artifact name, URL, path, or content term."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(String(localized: "artifactsPane.action.add", defaultValue: "Add Artifact"), action: presentAddPanel)
                    .controlSize(.small)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() async {
        let searched = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return }
        await artifactsState.refreshFromRepository()
        let resultRecords: [(record: ArtifactRecord, snippet: String?)]
        if scope == .global {
            let records = await artifactsState.globalRecords(
                query: searched,
                limit: 500,
                kind: kindFilter.kind,
                kindGroup: kindFilter.kindGroup,
                source: selectedSource,
                host: selectedHost
            )
            resultRecords = records.map { ($0.record, $0.snippet) }
        } else {
            let source = artifactsState.artifactRecords
            let request = ArtifactSearchQuery(
                text: searched,
                scope: .workspace(workspace.id.uuidString),
                limit: 500,
                kind: kindFilter.kind,
                kindGroup: kindFilter.kindGroup,
                source: selectedSource,
                host: selectedHost
            )
            let result = try? await Task.detached(priority: .userInitiated) {
                try ArtifactSearchEngine().results(records: source, query: request)
            }.value
            resultRecords = result?.map { ($0.record, $0.snippet) } ?? []
        }
        guard !Task.isCancelled else { return }
        rows = resultRecords.map { makeRow($0.record, snippet: $0.snippet) }
        let allRecords = scope == .global
            ? resultRecords.map(\.record)
            : artifactsState.artifactRecords
        hostOptions = Array(Set(allRecords.compactMap(\.hostKey))).sorted()
        sourceOptions = Array(Set(allRecords.map(\.source))).sorted { $0.rawValue < $1.rawValue }
        dayBuckets = makeDayBuckets(rows)
    }

    private func fetchVisibleTitles() async {
        guard artifactsState.fetchTitlesEnabled else { return }
        for row in rows.prefix(32) where row.record.kind == .url {
            guard !Task.isCancelled, let entry = artifactsState.entry(for: row.id) else { return }
            await titleFetcher.fetchTitleIfNeeded(for: entry, linksState: artifactsState)
        }
    }

    private func makeRow(_ record: ArtifactRecord, snippet: String? = nil) -> ArtifactPaneRowSnapshot {
        let ownerTitle = record.ownership.workspaceTitle
            ?? record.ownership.workspaceID.flatMap { UUID(uuidString: $0) }.flatMap { AppDelegate.shared?.workspaceFor(tabId: $0)?.title }
        let value: String = {
            switch record.representation {
            case .url(let value), .directory(let value): return value
            case .managedFile(_, let suggestedFileName): return suggestedFileName
            case .inlineText(let value), .inlineHTML(let value): return record.title ?? String(value.split(separator: "\n").first ?? "Artifact")
            }
        }()
        let kind = kindLabel(record.kind)
        let detail = String.localizedStringWithFormat(
            String(localized: "artifactsPane.row.detail", defaultValue: "%@ · %@"),
            kind,
            record.lastSeenAt.formatted(date: .abbreviated, time: .shortened)
        )
        return ArtifactPaneRowSnapshot(record: record, ownerTitle: ownerTitle, displayValue: value, detail: detail, snippet: snippet)
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard let selectedID,
              let row = rows.first(where: { $0.id == selectedID }) else { return .ignored }
        if press.key == .return {
            if press.modifiers.contains(.command) {
                ArtifactActionRouter().openExternal(row.record)
            } else {
                ArtifactActionRouter().open(row.record, from: workspace)
            }
            return .handled
        }
        if press.key == "c", press.modifiers == .command {
            copy(row.record.copyValue)
            return .handled
        }
        return .ignored
    }

    private func presentAddPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "artifactsPane.addPanel.title", defaultValue: "Add to Artifacts")
        panel.message = String(localized: "artifactsPane.addPanel.message", defaultValue: "Choose files or folders to save in the workspace artifact catalog.")
        panel.prompt = String(localized: "artifactsPane.addPanel.prompt", defaultValue: "Add")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { @MainActor in
                _ = await workspace.captureArtifact(
                    url.hasDirectoryPath ? .directory(url) : .file(url),
                    source: .manual,
                    authorization: .explicitUser
                )
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func remove(_ record: ArtifactRecord) {
        artifactsState.remove(id: record.id)
    }

    private func countText(_ count: Int) -> String {
        count == 1
            ? String(localized: "artifactsPane.count.one", defaultValue: "1 Artifact")
            : String(localized: "artifactsPane.count.other", defaultValue: "\(count) Artifacts")
    }

    private func kindLabel(_ kind: ArtifactKind) -> String {
        switch kind {
        case .url: String(localized: "artifactsPane.kind.url", defaultValue: "URL")
        case .html: String(localized: "artifactsPane.kind.html", defaultValue: "HTML")
        case .file: String(localized: "artifactsPane.kind.file", defaultValue: "File")
        case .text: String(localized: "artifactsPane.kind.text", defaultValue: "Text")
        case .code: String(localized: "artifactsPane.kind.code", defaultValue: "Code")
        case .json: String(localized: "artifactsPane.kind.json", defaultValue: "JSON")
        case .image: String(localized: "artifactsPane.kind.image", defaultValue: "Image")
        case .pdf: String(localized: "artifactsPane.kind.pdf", defaultValue: "PDF")
        case .audio: String(localized: "artifactsPane.kind.audio", defaultValue: "Audio")
        case .video: String(localized: "artifactsPane.kind.video", defaultValue: "Video")
        case .directory: String(localized: "artifactsPane.kind.directory", defaultValue: "Folder")
        case .browserDownload: String(localized: "artifactsPane.kind.browserDownload", defaultValue: "Download")
        case .generated: String(localized: "artifactsPane.kind.generated", defaultValue: "Generated")
        case .manual: String(localized: "artifactsPane.kind.manual", defaultValue: "Manual")
        case .unknown(let raw): raw
        }
    }

    private func sourceLabel(_ source: ArtifactSource) -> String {
        String.localizedStringWithFormat(
            String(localized: "artifactsPane.source.value", defaultValue: "%@"),
            source.rawValue
        )
    }

    private func makeDayBuckets(_ rows: [ArtifactPaneRowSnapshot]) -> [ArtifactPaneDayBucket] {
        var byDay: [Date: [ArtifactPaneRowSnapshot]] = [:]
        for row in rows {
            byDay[Calendar.current.startOfDay(for: row.record.lastSeenAt), default: []].append(row)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let now = Date.now
        return byDay.keys.sorted(by: >).map { day in
            let title = Calendar.current.isDateInToday(day)
                ? String(localized: "artifactsPane.day.today", defaultValue: "Today")
                : formatter.localizedString(for: day, relativeTo: now)
            return ArtifactPaneDayBucket(id: day, title: title, rows: byDay[day] ?? [])
        }
    }
}

private enum ArtifactPaneScope: String {
    case workspace
    case global
}

private enum ArtifactPaneKindFilter: String, CaseIterable, Hashable {
    case all
    case links
    case html
    case files

    var label: String {
        switch self {
        case .all: String(localized: "artifactsPane.kindFilter.all", defaultValue: "All Kinds")
        case .links: String(localized: "artifactsPane.kindFilter.links", defaultValue: "Links")
        case .html: String(localized: "artifactsPane.kindFilter.html", defaultValue: "HTML")
        case .files: String(localized: "artifactsPane.kindFilter.files", defaultValue: "Files")
        }
    }

    var kind: ArtifactKind? {
        switch self {
        case .all: nil
        case .links: nil
        case .html: .html
        case .files: nil
        }
    }

    var kindGroup: ArtifactKindGroup? {
        switch self {
        case .all: nil
        case .links: .links
        case .html: .html
        case .files: .files
        }
    }
}

private struct ArtifactPaneDayBucket: Identifiable {
    let id: Date
    let title: String
    let rows: [ArtifactPaneRowSnapshot]
}
