import CmuxFoundation
import AppKit
import SwiftUI

@MainActor
final class MenubarSearchPopover: NSObject, NSPopoverDelegate {
    private unowned let coordinator: GlobalSearchCoordinator
    private let popover = NSPopover()

    var isShown: Bool {
        popover.isShown
    }

    init(coordinator: GlobalSearchCoordinator) {
        self.coordinator = coordinator
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 720, height: 460)
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: GlobalSearchPaletteView(coordinator: coordinator)
        )
    }

    private var dismissalHandler: (() -> Void)?

    func toggle(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            dismiss()
        } else {
            show(relativeTo: button, onDismiss: onDismiss)
        }
    }

    func show(relativeTo button: NSStatusBarButton, onDismiss: (() -> Void)? = nil) {
        if popover.isShown {
            popover.performClose(nil)
        }
        dismissalHandler = onDismiss
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func dismiss() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        let handler = dismissalHandler
        dismissalHandler = nil
        handler?()
    }
}

private struct GlobalSearchPaletteView: View {
    let coordinator: GlobalSearchCoordinator

    @State private var query = ""
    @State private var results: [GlobalSearchResultRow] = []
    @State private var selectedIndex = 0
    @State private var isSearching = false
    @State private var searchGeneration = 0
    @State private var searchDebounceTimer: DispatchSourceTimer?
    @State private var searchTask: Task<Void, Never>?
    @State private var refreshTask: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @FocusState private var searchFieldFocused: Bool

    private let searchDebounceMilliseconds = 80
    private let browseResultLimit = 20

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .cmuxFont(size: 15, weight: .semibold)
                    .foregroundStyle(.secondary)
                TextField(
                    String(
                        localized: "globalSearch.palette.placeholder",
                        defaultValue: "Search all windows, panels, browser tabs..."
                    ),
                    text: $query
                )
                .textFieldStyle(.plain)
                .cmuxFont(size: 18, weight: .regular)
                .focused($searchFieldFocused)
            }
            .padding(.horizontal, 18)
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
    }

    private func scheduleSearch(_ nextQuery: String) {
        cancelSearchWork()
        searchGeneration += 1
        let generation = searchGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isSearching = false
            reloadBrowseResults()
            return
        }

        isSearching = true

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
                    let hits = await coordinator.search(query: trimmed)
                    guard searchGeneration == generation, !Task.isCancelled else { return }
                    results = hits.enumerated().map { offset, hit in
                        GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
                    }
                    selectedIndex = min(selectedIndex, max(results.count - 1, 0))
                    isSearching = false
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
            isSearching = false
        } else {
            results = []
            isSearching = true
        }
    }

    private func reloadBrowseResults() {
        let hits = coordinator.browseOpenPanels(limit: browseResultLimit)
        results = hits.enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: "", index: offset)
        }
        selectedIndex = 0
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

        let flags = event.modifierFlags
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            openResult(at: digit - 1)
            return true
        }

        switch event.keyCode {
        case 53:
            coordinator.dismissPalette()
            return true
        case 126:
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125:
            selectedIndex = min(max(results.count - 1, 0), selectedIndex + 1)
            return true
        case 36, 76:
            openSelectedResult()
            return true
        default:
            if flags.contains(.command),
               !flags.contains(.option),
               !flags.contains(.control) {
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

    private func openSelectedResult() {
        openResult(at: selectedIndex)
    }

    private func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }
}

private struct GlobalSearchKeyEvent: Sendable {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String?
    private let modifierFlagsRawValue: UInt

    init(_ event: NSEvent) {
        keyCode = event.keyCode
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        modifierFlagsRawValue = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    }
}

private struct GlobalSearchEmptyStateView: View {
    let title: String

    var body: some View {
        Text(title)
            .cmuxFont(size: 14, weight: .medium)
            .foregroundStyle(.secondary)
    }
}

private struct GlobalSearchResultRow: Identifiable, Equatable {
    let hit: SearchIndexHit
    let query: String
    let index: Int

    var id: String { hit.id }

    var title: String {
        let trimmed = hit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? String(localized: "globalSearch.untitled", defaultValue: "Untitled")
            : trimmed
    }

    var location: String {
        hit.location.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var snippet: String {
        let trimmed = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    var shortcutLabel: String? {
        index < 9 ? "⌘\(index + 1)" : nil
    }

    var systemImageName: String {
        switch hit.kind {
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .title:
            return "rectangle.stack"
        }
    }
}

private struct GlobalSearchResultRowView: View {
    let row: GlobalSearchResultRow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: row.systemImageName)
                    .cmuxFont(size: 14, weight: .semibold)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(row.title)
                            .cmuxFont(size: 13, weight: .semibold)
                            .lineLimit(1)
                        Text(row.hit.kind.localizedLabel)
                            .cmuxFont(size: 11, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(row.snippet)
                        .cmuxFont(size: 12)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if !row.location.isEmpty {
                        Text(row.location)
                            .cmuxFont(size: 11)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let shortcutLabel = row.shortcutLabel {
                    Text(shortcutLabel)
                        .cmuxFont(size: 11, weight: .medium, design: .monospaced)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
