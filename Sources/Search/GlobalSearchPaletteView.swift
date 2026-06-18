import AppKit
import SwiftUI

struct GlobalSearchPaletteView: View {
    let coordinator: GlobalSearchCoordinator

    @State private var query = ""
    @State private var results: [GlobalSearchResultRow] = []
    @State private var selectedIndex = 0
    @State private var activeKindIDs: Set<String> = []
    @State private var searchGeneration = 0
    @State private var searchDebounceTimer: DispatchSourceTimer?
    @State private var searchTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @FocusState private var searchFieldFocused: Bool

    private let searchDebounceMilliseconds = 80
    private let resultLimit = 20
    private let scopedSearchFetchLimit = 80

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "globalSearch.palette.placeholder",
                        defaultValue: "Search all windows, panels, browser tabs..."
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($searchFieldFocused)

                scopeButton(
                    systemName: "rectangle.stack",
                    isActive: activeKindIDs.isEmpty,
                    help: String(localized: "globalSearch.scope.allTabs", defaultValue: "All windows and tabs")
                ) {
                    activeKindIDs.removeAll()
                }

                kindScopeButton(.title, systemName: "macwindow")
                kindScopeButton(.browser, systemName: "globe")
                kindScopeButton(.markdown, systemName: "doc.richtext")

                Text(resultCounterText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                findbarButton(
                    systemName: "chevron.up",
                    help: String(localized: "globalSearch.navigate.previous", defaultValue: "Previous result")
                ) {
                    moveSelection(delta: -1)
                }
                .disabled(results.isEmpty)

                findbarButton(
                    systemName: "chevron.down",
                    help: String(localized: "globalSearch.navigate.next", defaultValue: "Next result")
                ) {
                    moveSelection(delta: 1)
                }
                .disabled(results.isEmpty)

                findbarButton(
                    systemName: "xmark",
                    help: String(localized: "globalSearch.close", defaultValue: "Close")
                ) {
                    coordinator.dismissPalette()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 56)

            Divider()

            if results.isEmpty {
                GlobalSearchEmptyStateView(
                    title: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? String(localized: "globalSearch.empty.noOpenPanels", defaultValue: "No open panels")
                        : String(localized: "globalSearch.empty.noResults", defaultValue: "No results")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { row in
                            GlobalSearchResultRowView(
                                row: row,
                                isSelected: selectedIndex == row.index,
                                action: {
                                    selectedIndex = row.index
                                    openSelectedResult()
                                }
                            )
                            .onHover { hovering in
                                if hovering {
                                    selectedIndex = row.index
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 720, height: 460)
        .background(.regularMaterial)
        .onAppear {
            searchFieldFocused = true
            installKeyMonitorIfNeeded()
            resetResultsForPopoverOpen()
            refreshTask?.cancel()
            refreshTask = Task { @MainActor in
                await coordinator.refreshLiveIndex()
                guard !Task.isCancelled else { return }
                scheduleSearch(query)
            }
        }
        .onDisappear {
            removeKeyMonitor()
            refreshTask?.cancel()
            refreshTask = nil
            cancelSearchWork()
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(newValue)
        }
        .onChange(of: activeKindIDs) { _, _ in
            scheduleSearch(query)
        }
    }

    private var resultCounterText: String {
        guard !results.isEmpty else { return "0/0" }
        return "\(selectedIndex + 1)/\(results.count)"
    }

    private func kindScopeButton(_ kind: GlobalSearchKind, systemName: String) -> some View {
        scopeButton(systemName: systemName, isActive: activeKindIDs.contains(kind.rawValue), help: kind.localizedLabel) {
            if activeKindIDs.contains(kind.rawValue) {
                activeKindIDs.remove(kind.rawValue)
            } else {
                activeKindIDs.insert(kind.rawValue)
            }
        }
    }

    private func scopeButton(
        systemName: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 25, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func findbarButton(
        systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func scheduleSearch(_ nextQuery: String) {
        cancelSearchWork()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reloadBrowseResults()
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(searchDebounceMilliseconds), leeway: .milliseconds(15))
        timer.setEventHandler {
            Task { @MainActor in
                guard searchGeneration == generation else { return }
                searchDebounceTimer?.cancel()
                searchDebounceTimer = nil

                searchTask = Task { @MainActor in
                    defer {
                        if searchGeneration == generation {
                            searchTask = nil
                        }
                    }

                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    let fetchLimit = activeKindIDs.isEmpty ? resultLimit : scopedSearchFetchLimit
                    let hits = await coordinator.search(query: trimmed, limit: fetchLimit)
                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    applyHits(hits, query: trimmed)
                }
            }
        }
        searchDebounceTimer = timer
        timer.resume()
    }

    private func cancelSearchWork() {
        searchDebounceTimer?.cancel()
        searchDebounceTimer = nil
        searchTask?.cancel()
        searchTask = nil
    }

    private func resetResultsForPopoverOpen() {
        selectedIndex = 0
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reloadBrowseResults()
        } else {
            results = []
        }
    }

    private func reloadBrowseResults() {
        applyHits(coordinator.browseOpenPanels(limit: scopedSearchFetchLimit), query: "")
    }

    private func applyHits(_ hits: [SearchIndexHit], query: String) {
        let filtered = activeKindIDs.isEmpty ? hits : hits.filter { activeKindIDs.contains($0.kind.rawValue) }
        results = filtered.prefix(resultLimit).enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: query, index: offset)
        }
        selectedIndex = min(selectedIndex, max(results.count - 1, 0))
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let consumed = MainActor.assumeIsolated {
                handleKeyEvent(keyEvent)
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard coordinator.isPaletteVisible() else { return false }

        if event.hasExactModifiers(.command),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            openResult(at: digit - 1)
            return true
        }

        if event.hasExactModifiers(.command),
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            moveSelection(delta: 1)
            return true
        }

        if event.hasExactModifiers([.command, .option]),
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            moveSelection(delta: -1)
            return true
        }

        switch event.keyCode {
        case 53:
            coordinator.dismissPalette()
            return true
        case 126:
            moveSelection(delta: -1)
            return true
        case 125:
            moveSelection(delta: 1)
            return true
        case 36, 76:
            openSelectedResult()
            return true
        default:
            if event.hasExactModifiers(.command) {
                return !isTextEditingCommand(event) && !isSystemCommand(event)
            }
            return false
        }
    }

    private func isTextEditingCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        if let characters = event.charactersIgnoringModifiers?.lowercased(),
           ["a", "c", "v", "x", "z"].contains(characters) {
            return true
        }

        switch event.keyCode {
        case 51, 117, 123, 124:
            return true
        default:
            return false
        }
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
    }

    private func moveSelection(delta: Int) {
        guard !results.isEmpty else { return }
        let nextIndex = min(max(results.count - 1, 0), max(0, selectedIndex + delta))
        selectedIndex = nextIndex
        previewResult(at: nextIndex)
    }

    private func openSelectedResult() {
        openResult(at: selectedIndex)
    }

    private func previewResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.preview(row.hit, query: row.query)
    }

    private func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }
}
