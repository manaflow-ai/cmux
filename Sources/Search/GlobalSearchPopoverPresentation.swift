import AppKit
import Observation

@MainActor
@Observable
final class GlobalSearchPopoverPresentation {
    var query = "" {
        didSet {
            guard isPresented, query != oldValue else { return }
            scheduleSearch(query)
        }
    }
    private(set) var results: [GlobalSearchResultRow] = []
    private(set) var selectedIndex = 0
    private(set) var isPresented = false

    @ObservationIgnored private unowned let coordinator: GlobalSearchCoordinator
    @ObservationIgnored private let refreshLivePanelTitles: @MainActor @Sendable () async -> Void
    @ObservationIgnored private let search: @MainActor @Sendable (String) async -> [SearchIndexHit]
    @ObservationIgnored private let debounceSleep: @MainActor @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var presentationGeneration = 0
    @ObservationIgnored private var searchWorkGeneration = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?

    private let searchDebounceDuration = Duration.milliseconds(80)
    private let browseResultLimit = 20

    init(
        coordinator: GlobalSearchCoordinator,
        refreshLivePanelTitles: (@MainActor @Sendable () async -> Void)? = nil,
        search: (@MainActor @Sendable (String) async -> [SearchIndexHit])? = nil,
        debounceSleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
            try await ContinuousClock().sleep(for: $0)
        }
    ) {
        self.coordinator = coordinator
        self.refreshLivePanelTitles = refreshLivePanelTitles ?? { [unowned coordinator] in
            await coordinator.refreshLivePanelTitles()
        }
        self.search = search ?? { [unowned coordinator] query in
            await coordinator.search(query: query)
        }
        self.debounceSleep = debounceSleep
    }

    func beginPresentation() {
        presentationGeneration &+= 1
        let generation = presentationGeneration

        cancelRefreshWork()
        cancelSearchWork()
        query = ""
        reloadBrowseResults()
        isPresented = true
        installKeyMonitorIfNeeded()

        let refreshLivePanelTitles = self.refreshLivePanelTitles
        refreshTask = Task { @MainActor [weak self] in
            await refreshLivePanelTitles()
            guard let self else { return }
            guard !Task.isCancelled,
                  isPresented,
                  presentationGeneration == generation else {
                return
            }
            refreshTask = nil
            scheduleSearch(query)
        }
    }

    func endPresentation() {
        presentationGeneration &+= 1
        isPresented = false
        cancelRefreshWork()
        cancelSearchWork()
        removeKeyMonitor()
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func activateSelectedResult() {
        activateResult(at: selectedIndex)
    }

    private func scheduleSearch(_ nextQuery: String) {
        cancelSearchWork()
        let generation = searchWorkGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reloadBrowseResults()
            return
        }

        let debounceSleep = self.debounceSleep
        let debounceDuration = searchDebounceDuration
        searchTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do {
                try await debounceSleep(debounceDuration)
            } catch {
                if let self, searchWorkGeneration == generation {
                    searchTask = nil
                }
                return
            }

            guard let self else { return }
            defer {
                if searchWorkGeneration == generation {
                    searchTask = nil
                }
            }

            guard isPresented,
                  searchWorkGeneration == generation,
                  !Task.isCancelled else {
                return
            }
            let hits = await search(trimmed)
            guard isPresented,
                  searchWorkGeneration == generation,
                  !Task.isCancelled else {
                return
            }
            results = hits.enumerated().map { offset, hit in
                GlobalSearchResultRow(hit: hit, query: trimmed, index: offset)
            }
            selectedIndex = min(selectedIndex, max(results.count - 1, 0))
        }
    }

    private func cancelRefreshWork() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func cancelSearchWork() {
        searchWorkGeneration &+= 1
        searchTask?.cancel()
        searchTask = nil
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
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyEvent = GlobalSearchKeyEvent(event)
            let route = MainActor.assumeIsolated {
                AppDelegate.shared?
                    .routeVisibleGlobalSearchShortcutFromLocalMonitor(event)
                    ?? .notApplicable
            }
            switch route {
            case .handled:
                return nil
            case .queryOwnsEvent:
                return event
            case .notApplicable:
                let consumed = MainActor.assumeIsolated {
                    self?.routeKeyEvent(keyEvent) ?? false
                }
                return consumed ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func routeKeyEvent(_ event: GlobalSearchKeyEvent) -> Bool {
        guard isPresented else { return false }

        let flags = event.modifierFlags
        if flags.contains(.command),
           !flags.contains(.option),
           !flags.contains(.control),
           let rawDigit = event.charactersIgnoringModifiers,
           let digit = Int(rawDigit),
           (1...9).contains(digit) {
            activateResult(at: digit - 1)
            return true
        }

        switch event.keyCode {
        case 53:
            coordinator.dismissPalette()
            return true
        case 126 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case 125 where flags.isDisjoint(with: [.command, .shift, .option, .control]):
            selectedIndex = min(max(results.count - 1, 0), selectedIndex + 1)
            return true
        case 36, 76:
            activateSelectedResult()
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

    private func activateResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        let row = results[index]
        coordinator.activate(row.hit, query: row.query)
    }

    private func isSystemCommand(_ event: GlobalSearchKeyEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return ["h", "m", "q", "w", ","].contains(characters)
    }
}
