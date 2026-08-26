import AppKit
import SwiftUI

struct LinksPanelView: View {
    @ObservedObject var panel: LinksPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            if let workspace = panel.workspace {
                LinksPaneContent(
                    workspace: workspace,
                    linksState: workspace.linksState,
                    titleFetcher: panel.titleFetcher,
                    isFocused: isFocused
                )
            } else {
                Text(String(
                    localized: "linksPane.workspaceUnavailable",
                    defaultValue: "This workspace is no longer available."
                ))
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onRequestPanelFocus() }
    }
}

private struct LinksPaneContent: View {
    let workspace: Workspace
    let linksState: WorkspaceLinksState
    let titleFetcher: LinkTitleFetcher
    let isFocused: Bool

    @State private var substringFilter = ""
    @State private var selectedHost: String?
    @State private var selectedSourcePanelId: UUID?
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        let projection = makeProjection()
        VStack(spacing: 0) {
            toolbar(projection: projection)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if projection.filteredEntries.isEmpty {
                Text(emptyText(allEntriesEmpty: projection.allEntriesCount == 0))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(projection.dayBuckets, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                LinksPanelRow(
                                    entry: entry,
                                    actions: rowActions(for: entry)
                                )
                                .tag(entry.id)
                            }
                        } header: {
                            Text(group.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(.sidebar)
                .focused($listFocused)
                .onKeyPress { handleKeyPress($0, entries: projection.filteredEntries) }
                .onAppear { if isFocused { listFocused = true } }
                .onChange(of: isFocused) { _, focused in
                    if focused { listFocused = true }
                }
            }
        }
        .accessibilityIdentifier("LinksPane")
    }

    private func emptyText(allEntriesEmpty: Bool) -> String {
        if allEntriesEmpty {
            return String(localized: "linksPane.empty", defaultValue: "No links captured yet.")
        }
        return String(localized: "linksPane.emptyFiltered", defaultValue: "No links match the current filters.")
    }

    private func toolbar(projection: LinksPanelProjection) -> some View {
        HStack(spacing: 8) {
            TextField(
                String(localized: "linksPane.search.placeholder", defaultValue: "Filter links"),
                text: $substringFilter
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 160)

            Menu(hostMenuTitle) {
                Button(String(localized: "linksPane.host.all", defaultValue: "All Hosts")) {
                    selectedHost = nil
                }
                ForEach(projection.hosts, id: \.self) { host in
                    Button(host) { selectedHost = host }
                }
            }

            Menu(sourceMenuTitle(selectedTitle: projection.selectedSourceTitle)) {
                Button(String(localized: "linksPane.source.all", defaultValue: "All Surfaces")) {
                    selectedSourcePanelId = nil
                }
                ForEach(projection.sources, id: \.id) { source in
                    Button(source.title) { selectedSourcePanelId = source.id }
                }
            }

            Spacer(minLength: 8)
            Text(countText(projection.filteredEntries.count))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var hostMenuTitle: String {
        selectedHost ?? String(localized: "linksPane.host.all", defaultValue: "All Hosts")
    }

    private func sourceMenuTitle(selectedTitle: String?) -> String {
        guard let selectedTitle else {
            return String(localized: "linksPane.source.all", defaultValue: "All Surfaces")
        }
        return selectedTitle
    }

    private func makeProjection() -> LinksPanelProjection {
        let query = substringFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = linksState.entries
        var hostSet: Set<String> = []
        var sourceIDs: Set<UUID> = []
        var sources: [LinksPanelSourceOption] = []
        var filteredEntries: [WorkspaceCapturedLink] = []
        var dayBuckets: [LinksPanelDayBucket] = []
        var dayIndex: [Date: Int] = [:]
        var selectedSourceTitle: String?
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let now = Date()

        for entry in entries {
            if let hostKey = entry.hostKey {
                hostSet.insert(hostKey)
            }
            if let sourceID = entry.sourcePanelId {
                let title = entry.sourceSurfaceTitle ?? untitledSourceTitle
                if sourceIDs.insert(sourceID).inserted {
                    sources.append(LinksPanelSourceOption(id: sourceID, title: title))
                }
                if sourceID == selectedSourcePanelId {
                    selectedSourceTitle = title
                }
            }

            if let selectedHost, entry.hostKey != selectedHost { continue }
            if let selectedSourcePanelId, entry.sourcePanelId != selectedSourcePanelId { continue }
            if !query.isEmpty,
               !entry.url.lowercased().contains(query),
               !(entry.hostKey?.lowercased().contains(query) ?? false),
               !(entry.sourceSurfaceTitle?.lowercased().contains(query) ?? false) {
                continue
            }

            filteredEntries.append(entry)
            let day = Calendar.current.startOfDay(for: entry.lastSeen)
            if let index = dayIndex[day] {
                dayBuckets[index].entries.append(entry)
            } else {
                dayIndex[day] = dayBuckets.count
                dayBuckets.append(LinksPanelDayBucket(
                    day: day,
                    title: dayTitle(day, formatter: formatter, now: now),
                    entries: [entry]
                ))
            }
        }
        return LinksPanelProjection(
            allEntriesCount: entries.count,
            filteredEntries: filteredEntries,
            hosts: hostSet.sorted(),
            sources: sources,
            selectedSourceTitle: selectedSourceTitle,
            dayBuckets: dayBuckets
        )
    }

    private var untitledSourceTitle: String {
        String(localized: "linksPane.source.untitled", defaultValue: "Untitled Surface")
    }

    private func dayTitle(_ day: Date, formatter: RelativeDateTimeFormatter, now: Date) -> String {
        Calendar.current.isDateInToday(day)
            ? String(localized: "linksPane.day.today", defaultValue: "Today")
            : formatter.localizedString(for: day, relativeTo: now)
    }

    private func countText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "linksPane.count.one", defaultValue: "\(count) Link")
        }
        return String(localized: "linksPane.count.other", defaultValue: "\(count) Links")
    }

    private func rowActions(for entry: WorkspaceCapturedLink) -> LinksPanelRowActions {
        LinksPanelRowActions(
            openPreferred: { openPreferred(entry) },
            openBuiltIn: { openBuiltIn(entry) },
            openExternal: { openExternal(entry) },
            copy: { copy(entry.url) },
            reveal: { reveal(entry) },
            remove: { linksState.remove(id: entry.id) },
            clearAll: { linksState.clearAll() },
            fetchTitle: { entry in
                await titleFetcher.fetchTitleIfNeeded(for: entry, linksState: linksState)
            }
        )
    }

    private func handleKeyPress(_ press: KeyPress, entries: [WorkspaceCapturedLink]) -> KeyPress.Result {
        guard let id = selection, let entry = entries.first(where: { $0.id == id }) else { return .ignored }
        if press.key == .return && press.modifiers.contains(.command) {
            openExternal(entry)
            return .handled
        }
        if press.key == .return && press.modifiers.isEmpty {
            openPreferred(entry)
            return .handled
        }
        if press.key == "c" && press.modifiers == .command {
            copy(entry.url)
            return .handled
        }
        return .ignored
    }

    private func openPreferred(_ entry: WorkspaceCapturedLink) {
        _ = TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
            rawValue: entry.url,
            sourceWorkspaceId: workspace.id,
            sourcePanelId: entry.sourcePanelId,
            workingDirectory: nil
        ))
    }

    private func openBuiltIn(_ entry: WorkspaceCapturedLink) {
        guard let url = URL(string: entry.url) else { return }
        if let sourcePanelId = entry.sourcePanelId,
           workspace.openTerminalBrowserLink(url: url, sourcePanelId: sourcePanelId) {
            return
        }
        _ = workspace.owningTabManager?.openBrowser(
            inWorkspace: workspace.id,
            url: url,
            preferSplitRight: true
        )
    }

    private func openExternal(_ entry: WorkspaceCapturedLink) {
        guard let url = URL(string: entry.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    private func reveal(_ entry: WorkspaceCapturedLink) {
        // Stream capture has no stable row identity, so reveal focuses the
        // source surface without attempting scroll-to-line.
        guard let sourcePanelId = entry.sourcePanelId else { return }
        workspace.focusPanel(sourcePanelId)
    }
}

private struct LinksPanelProjection {
    var allEntriesCount: Int
    var filteredEntries: [WorkspaceCapturedLink]
    var hosts: [String]
    var sources: [LinksPanelSourceOption]
    var selectedSourceTitle: String?
    var dayBuckets: [LinksPanelDayBucket]
}

private struct LinksPanelSourceOption: Identifiable {
    var id: UUID
    var title: String
}

private struct LinksPanelDayBucket {
    var day: Date
    var title: String
    var entries: [WorkspaceCapturedLink]
}

private struct LinksPanelRowActions {
    var openPreferred: () -> Void
    var openBuiltIn: () -> Void
    var openExternal: () -> Void
    var copy: () -> Void
    var reveal: () -> Void
    var remove: () -> Void
    var clearAll: () -> Void
    var fetchTitle: (WorkspaceCapturedLink) async -> Void
}

private struct LinksPanelRow: View {
    let entry: WorkspaceCapturedLink
    let actions: LinksPanelRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.url)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.url)
            if let title = entry.fetchedTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 6) {
                Text(sourceText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if entry.count > 1 {
                    Text(String(
                        localized: "linksPane.repeatCount",
                        defaultValue: "×\(entry.count)"
                    ))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.openPreferred() }
        .task(id: entry.id) {
            await actions.fetchTitle(entry)
        }
        .contextMenu {
            Button(String(localized: "linksPane.action.copy", defaultValue: "Copy Link"), action: actions.copy)
            Button(String(localized: "linksPane.action.openBuiltIn", defaultValue: "Open in Built-in Browser"), action: actions.openBuiltIn)
            Button(String(localized: "linksPane.action.openDefault", defaultValue: "Open in Default Browser"), action: actions.openExternal)
            Button(String(localized: "linksPane.action.reveal", defaultValue: "Reveal in Pane"), action: actions.reveal)
            Divider()
            Button(String(localized: "linksPane.action.remove", defaultValue: "Remove Link"), action: actions.remove)
            Button(String(localized: "linksPane.action.clearAll", defaultValue: "Clear All Links"), action: actions.clearAll)
        }
    }

    private var sourceText: String {
        let source = entry.sourceSurfaceTitle ?? String(localized: "linksPane.source.untitled", defaultValue: "Untitled Surface")
        let time = entry.lastSeen.formatted(date: .omitted, time: .shortened)
        return String(
            localized: "linksPane.row.sourceAndTime",
            defaultValue: "\(source) · \(time)"
        )
    }
}
