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
    @ObservedObject var workspace: Workspace
    @ObservedObject var linksState: WorkspaceLinksState
    let isFocused: Bool

    @State private var substringFilter = ""
    @State private var selectedHost: String?
    @State private var selectedSourcePanelId: UUID?
    @State private var selection: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        let entries = filteredEntries()
        VStack(spacing: 0) {
            toolbar(entries: linksState.entries, filteredCount: entries.count)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if entries.isEmpty {
                Text(emptyText)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(grouped(entries), id: \.day) { group in
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
                .onKeyPress { handleKeyPress($0, entries: entries) }
                .onAppear { if isFocused { listFocused = true } }
                .onChange(of: isFocused) { _, focused in
                    if focused { listFocused = true }
                }
            }
        }
        .accessibilityIdentifier("LinksPane")
    }

    private var emptyText: String {
        if linksState.entries.isEmpty {
            return String(localized: "linksPane.empty", defaultValue: "No links captured yet.")
        }
        return String(localized: "linksPane.emptyFiltered", defaultValue: "No links match the current filters.")
    }

    private func toolbar(entries: [WorkspaceCapturedLink], filteredCount: Int) -> some View {
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
                ForEach(distinctHosts(entries), id: \.self) { host in
                    Button(host) { selectedHost = host }
                }
            }

            Menu(sourceMenuTitle(entries: entries)) {
                Button(String(localized: "linksPane.source.all", defaultValue: "All Surfaces")) {
                    selectedSourcePanelId = nil
                }
                ForEach(distinctSources(entries), id: \.id) { source in
                    Button(source.title) { selectedSourcePanelId = source.id }
                }
            }

            Spacer(minLength: 8)
            Text(String(
                localized: "linksPane.count",
                defaultValue: "\(filteredCount) Links"
            ))
            .font(.system(size: 12).monospacedDigit())
            .foregroundColor(.secondary)
        }
    }

    private var hostMenuTitle: String {
        selectedHost ?? String(localized: "linksPane.host.all", defaultValue: "All Hosts")
    }

    private func sourceMenuTitle(entries: [WorkspaceCapturedLink]) -> String {
        guard let selectedSourcePanelId,
              let match = entries.first(where: { $0.sourcePanelId == selectedSourcePanelId }) else {
            return String(localized: "linksPane.source.all", defaultValue: "All Surfaces")
        }
        return match.sourceSurfaceTitle ?? String(localized: "linksPane.source.untitled", defaultValue: "Untitled Surface")
    }

    private func filteredEntries() -> [WorkspaceCapturedLink] {
        let query = substringFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return linksState.entries.filter { entry in
            if let selectedHost, entry.hostKey != selectedHost { return false }
            if let selectedSourcePanelId, entry.sourcePanelId != selectedSourcePanelId { return false }
            if !query.isEmpty,
               !entry.url.lowercased().contains(query),
               !(entry.hostKey?.lowercased().contains(query) ?? false),
               !(entry.sourceSurfaceTitle?.lowercased().contains(query) ?? false) {
                return false
            }
            return true
        }
    }

    private func distinctHosts(_ entries: [WorkspaceCapturedLink]) -> [String] {
        Array(Set(entries.compactMap(\.hostKey))).sorted()
    }

    private func distinctSources(_ entries: [WorkspaceCapturedLink]) -> [(id: UUID, title: String)] {
        var seen: Set<UUID> = []
        return entries.compactMap { entry in
            guard let id = entry.sourcePanelId, !seen.contains(id) else { return nil }
            seen.insert(id)
            return (id, entry.sourceSurfaceTitle ?? String(localized: "linksPane.source.untitled", defaultValue: "Untitled Surface"))
        }
    }

    private func grouped(_ entries: [WorkspaceCapturedLink]) -> [(day: Date, title: String, entries: [WorkspaceCapturedLink])] {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var groups: [(Date, [WorkspaceCapturedLink])] = []
        for entry in entries {
            let day = WorkspaceLinksDayGrouping.dayKey(for: entry.lastSeen)
            if let index = groups.firstIndex(where: { $0.0 == day }) {
                groups[index].1.append(entry)
            } else {
                groups.append((day, [entry]))
            }
        }
        return groups.map { day, entries in
            let title = Calendar.current.isDateInToday(day)
                ? String(localized: "linksPane.day.today", defaultValue: "Today")
                : formatter.localizedString(for: day, relativeTo: Date())
            return (day, title, entries)
        }
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
                await LinkTitleFetcher.shared.fetchTitleIfNeeded(for: entry, workspace: workspace)
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
        return "\(source) · \(entry.lastSeen.formatted(date: .omitted, time: .shortened))"
    }
}
