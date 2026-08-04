import AppKit
import Observation

@MainActor
@Observable
final class GlobalSearchPopoverPresentation {
    typealias DebounceCancellation = @MainActor () -> Void
    typealias DebounceScheduler = @MainActor (
        Int,
        @escaping @MainActor () -> Void
    ) -> DebounceCancellation

    var query = "" {
        didSet {
            guard isPresented, query != oldValue else { return }
            scheduleSearch(query, selectionUpdate: .reset)
        }
    }
    private(set) var results: [GlobalSearchResultRow] = []
    private(set) var selectedIndex = 0
    private(set) var isPresented = false

    @ObservationIgnored private unowned let coordinator: GlobalSearchCoordinator
    @ObservationIgnored private let refreshLiveIndex: @MainActor @Sendable () async -> Void
    @ObservationIgnored private let search: @MainActor @Sendable (String) async -> [SearchIndexHit]
    @ObservationIgnored private let scheduleSearchDebounce: DebounceScheduler
    @ObservationIgnored private var presentationGeneration = 0
    @ObservationIgnored private var searchWorkGeneration = 0
    @ObservationIgnored private var cancelScheduledSearchDebounce: DebounceCancellation?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var resultsQuery = ""

    private let searchDebounceMilliseconds = 80
    private let browseResultLimit = 20

    init(
        coordinator: GlobalSearchCoordinator,
        refreshLiveIndex: (@MainActor @Sendable () async -> Void)? = nil,
        search: (@MainActor @Sendable (String) async -> [SearchIndexHit])? = nil,
        scheduleSearchDebounce: @escaping DebounceScheduler = { milliseconds, action in
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(
                deadline: .now() + .milliseconds(max(0, milliseconds)),
                leeway: .milliseconds(10)
            )
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    action()
                }
            }
            timer.resume()
            return {
                timer.setEventHandler {}
                timer.cancel()
            }
        }
    ) {
        self.coordinator = coordinator
        self.refreshLiveIndex = refreshLiveIndex ?? { [unowned coordinator] in
            await coordinator.refreshLiveIndex()
        }
        self.search = search ?? { [unowned coordinator] query in
            await coordinator.search(query: query)
        }
        self.scheduleSearchDebounce = scheduleSearchDebounce
    }

    func beginPresentation() {
        presentationGeneration &+= 1
        let generation = presentationGeneration

        cancelRefreshWork()
        cancelSearchWork()
        query = ""
        reloadBrowseResults()
        isPresented = true
        coordinator.presentationDidBegin(self)
        installKeyMonitorIfNeeded()

        let refreshLiveIndex = self.refreshLiveIndex
        refreshTask = Task { @MainActor [weak self] in
            await refreshLiveIndex()
            guard let self else { return }
            guard !Task.isCancelled,
                  isPresented,
                  presentationGeneration == generation else {
                return
            }
            refreshTask = nil
            searchIndexDidChange()
        }
    }

    @discardableResult
    func endPresentation() -> Task<Void, Never>? {
        presentationGeneration &+= 1
        isPresented = false
        coordinator.presentationDidEnd(self)
        cancelRefreshWork()
        let cancelledSearchTask = cancelSearchWork()
        removeKeyMonitor()
        return cancelledSearchTask
    }

    func selectResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func activateSelectedResult() {
        activateResult(at: selectedIndex)
    }

    func searchIndexDidChange() {
        guard isPresented else { return }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        scheduleSearch(query, selectionUpdate: .preserveCurrentHit)
    }

    private func scheduleSearch(
        _ nextQuery: String,
        selectionUpdate: GlobalSearchPopoverSelectionUpdate
    ) {
        cancelSearchWork()
        let generation = searchWorkGeneration
        let trimmed = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reloadBrowseResults()
            return
        }

        let scheduleSearchDebounce = self.scheduleSearchDebounce
        cancelScheduledSearchDebounce = scheduleSearchDebounce(searchDebounceMilliseconds) { [weak self] in
            guard let self,
                  isPresented,
                  searchWorkGeneration == generation else {
                return
            }
            let cancelDebounce = cancelScheduledSearchDebounce
            cancelScheduledSearchDebounce = nil
            cancelDebounce?()
            startSearch(
                trimmed,
                generation: generation,
                selectionUpdate: selectionUpdate
            )
        }
    }

    private func startSearch(
        _ trimmedQuery: String,
        generation: Int,
        selectionUpdate: GlobalSearchPopoverSelectionUpdate
    ) {
        guard isPresented,
              searchWorkGeneration == generation else {
            return
        }

        let search = self.search
        searchTask = Task { @MainActor [weak self] in
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
            let hits = await search(trimmedQuery)
            guard isPresented,
                  searchWorkGeneration == generation,
                  !Task.isCancelled else {
                return
            }
            let selectedHitID: String? = if selectionUpdate == .preserveCurrentHit,
                                            resultsQuery == trimmedQuery,
                                            results.indices.contains(selectedIndex) {
                results[selectedIndex].hit.id
            } else {
                nil
            }
            let updatedResults = hits.enumerated().map { offset, hit in
                GlobalSearchResultRow(hit: hit, query: trimmedQuery, index: offset)
            }
            results = updatedResults
            resultsQuery = trimmedQuery
            selectedIndex = selectedHitID.flatMap { selectedHitID in
                updatedResults.firstIndex(where: { $0.hit.id == selectedHitID })
            } ?? 0
        }
    }

    private func cancelRefreshWork() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    @discardableResult
    private func cancelSearchWork() -> Task<Void, Never>? {
        searchWorkGeneration &+= 1
        cancelScheduledSearchDebounce?()
        cancelScheduledSearchDebounce = nil
        let cancelledSearchTask = searchTask
        cancelledSearchTask?.cancel()
        searchTask = nil
        return cancelledSearchTask
    }

    private func reloadBrowseResults() {
        let hits = coordinator.browseOpenPanels(limit: browseResultLimit)
        results = hits.enumerated().map { offset, hit in
            GlobalSearchResultRow(hit: hit, query: "", index: offset)
        }
        resultsQuery = ""
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
