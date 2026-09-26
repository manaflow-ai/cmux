import CmuxFoundation
import Foundation

/// Search state and per-open lifecycle for the global search palette.
///
/// The popover retains its SwiftUI content view across shows, so `onAppear` /
/// `onDisappear` fire only around the first open and cannot drive per-open
/// work (#7445). `MenubarSearchPopover` calls `prepareForOpen()` /
/// `handleDidClose()` from the AppKit show/close path instead; the SwiftUI
/// view is a renderer bound to this model.
@MainActor
final class GlobalSearchPaletteModel: ObservableObject {
    /// The palette's outward dependencies, injectable for tests.
    struct Client {
        var refreshLiveIndex: () async -> Void
        var search: (String) async -> [SearchIndexHit]
        var browseOpenPanels: (Int) -> [SearchIndexHit]
        var activate: (SearchIndexHit, String) -> Void
        var dismissPalette: () -> Void
        var isPaletteVisible: () -> Bool
    }

    @Published var query = ""
    @Published private(set) var results: [GlobalSearchResultRow] = []
    @Published var selectedIndex = 0
    @Published private(set) var isSearching = false
    /// Bumped on every popover open so the view can re-run per-open work
    /// (focusing the search field) that `onAppear` no longer covers.
    @Published private(set) var openGeneration = 0

    private let client: Client
    private let searchDebounceDelay: Duration
    private let browseResultLimit = 20
    private var searchGeneration = 0
    private let searchDebounceScheduler = MainActorDeferredActionScheduler()
    private let tasks = MainActorTaskStore<String>()

    init(client: Client, searchDebounceDelay: Duration = .milliseconds(80)) {
        self.client = client
        self.searchDebounceDelay = searchDebounceDelay
    }

    func prepareForOpen() {
        openGeneration += 1
        cancelSearchWork()
        query = ""
        selectedIndex = 0
        isSearching = false
        reloadBrowseResults()
        tasks.replaceOnMainActor("refresh") { [weak self] in
            guard let self else { return }
            await self.client.refreshLiveIndex()
            guard !Task.isCancelled else { return }
            self.scheduleSearch(self.query)
        }
    }

    func handleDidClose() {
        tasks.cancel("refresh")
        cancelSearchWork()
    }

    func queryDidChange(_ newValue: String) {
        scheduleSearch(newValue)
    }

    func openSelectedResult() {
        openResult(at: selectedIndex)
    }

    func openResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        client.activate(row.hit, row.query)
    }

    func handleKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard client.isPaletteVisible() else { return false }

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
            client.dismissPalette()
            return true
        case 126 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectedIndex = min(max(results.count - 1, 0), selectedIndex + 1)
            return true
        case 36, 76:
            openSelectedResult()
            return true
        default:
            if flags.contains(.command),
               !flags.contains(.option),
               !flags.contains(.control) {
                return !event.queryOwnsEditingShortcut && !isSystemCommand(event)
            }
            return false
        }
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
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

        searchDebounceScheduler.schedule(after: searchDebounceDelay) { [weak self] in
            guard let self, self.searchGeneration == generation else { return }
            self.tasks.replaceOnMainActor("search") { [weak self] in
                guard let self, self.searchGeneration == generation, !Task.isCancelled else { return }
                let hits = await self.client.search(trimmed)
                guard self.searchGeneration == generation, !Task.isCancelled else { return }
                self.results = hits.enumerated().map { offset, hit in
                    GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
                }
                self.selectedIndex = min(self.selectedIndex, max(self.results.count - 1, 0))
                self.isSearching = false
            }
        }
    }

    private func cancelSearchWork() {
        searchDebounceScheduler.cancel()
        tasks.cancel("search")
    }

    private func reloadBrowseResults() {
        let hits = client.browseOpenPanels(browseResultLimit)
        results = hits.enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: "", index: offset)
        }
        selectedIndex = 0
    }
}

struct GlobalSearchResultRow: Identifiable, Equatable {
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
            return "doc.richtext"
        case .terminal:
            return "terminal"
        case .title:
            return "rectangle.stack"
        }
    }
}
