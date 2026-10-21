import Foundation
import Observation

/// The find-window panel's state: the query, the pane texts read so far, and the results.
///
/// Opening the panel takes a snapshot of every mirrored pane and starts reading
/// their full tmux histories, one host at a time per host and one pane at a time
/// per host (see ``RemoteTmuxPaneTextReader``). Window names and titles match as
/// soon as the panel opens; content matches fill in as each pane's text arrives.
/// Matching runs off the main actor and a new keystroke cancels the previous run.
@MainActor
@Observable
final class RemoteTmuxFindWindowModel {
    /// What the model needs from the app, injected so tests can drive it.
    struct Environment {
        /// Every searchable pane, focused workspace first.
        var candidates: @MainActor () -> [RemoteTmuxFindWindowCandidate]
        /// Reads one pane's history and screen; nil when it can't be read.
        var readText: @MainActor (RemoteTmuxFindWindowCandidate) async -> RemoteTmuxPaneText?
        /// Goes to a result's tab and pane.
        var jump: @MainActor (RemoteTmuxFindWindowResult) -> Void
    }

    /// Pane text kept across all panes; panes past it are not read.
    static let maximumTextBytes = 64 * 1_024 * 1_024

    var query = "" {
        didSet { if query != oldValue { runSearch() } }
    }
    var options = RemoteTmuxFindWindowOptions() {
        didSet { if options != oldValue { runSearch() } }
    }
    private(set) var results: [RemoteTmuxFindWindowResult] = []
    private(set) var selectedIndex = 0
    /// Why the query can't run (a regex that does not compile).
    private(set) var queryError: String?
    private(set) var paneCount = 0
    /// Panes whose text has been read, or given up on.
    private(set) var settledPaneCount = 0
    /// Panes that could not be read or did not fit the memory budget.
    private(set) var unreadPaneCount = 0
    var isReadingHistory: Bool { settledPaneCount < paneCount }

    var selectedResult: RemoteTmuxFindWindowResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var candidates: [RemoteTmuxFindWindowCandidate] = []
    @ObservationIgnored private var texts: [RemoteTmuxFindWindowCandidate.ID: RemoteTmuxPaneText] = [:]
    @ObservationIgnored private var textBytes = 0
    @ObservationIgnored private var search: RemoteTmuxFindWindowSearch?
    @ObservationIgnored private var nameResults: [RemoteTmuxFindWindowResult] = []
    @ObservationIgnored private var contentResults: [RemoteTmuxFindWindowCandidate.ID: [RemoteTmuxFindWindowResult]] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var paneSearchTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var readTasks: [Task<Void, Never>] = []

    init(environment: Environment) {
        self.environment = environment
    }

    /// Snapshots the panes, starts reading their text and runs the current query.
    func open() {
        close()
        candidates = environment.candidates()
        paneCount = candidates.count
        settledPaneCount = 0
        unreadPaneCount = 0
        texts = [:]
        textBytes = 0
        runSearch()
        var hostOrder: [String] = []
        var panesByHost: [String: [RemoteTmuxFindWindowCandidate]] = [:]
        for candidate in candidates.sorted(by: { $0.order < $1.order }) {
            if panesByHost[candidate.id.hostKey] == nil { hostOrder.append(candidate.id.hostKey) }
            panesByHost[candidate.id.hostKey, default: []].append(candidate)
        }
        // One reader per host: a host's sessions share one control stream, and
        // reading its panes one after another keeps one capture in flight on it.
        readTasks = hostOrder.compactMap { panesByHost[$0] }.map { panes in
            Task { @MainActor [weak self] in
                for pane in panes {
                    guard let self, !Task.isCancelled else { return }
                    await self.read(pane)
                }
            }
        }
    }

    /// Stops reading and matching.
    func close() {
        readTasks.forEach { $0.cancel() }
        readTasks = []
        searchTask?.cancel()
        searchTask = nil
        paneSearchTasks.forEach { $0.cancel() }
        paneSearchTasks = []
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), results.count - 1)
    }

    func select(_ result: RemoteTmuxFindWindowResult) {
        if let index = results.firstIndex(where: { $0.id == result.id }) { selectedIndex = index }
    }

    /// Jumps to the selected result. Returns false when nothing is selected.
    @discardableResult
    func activateSelection() -> Bool {
        guard let result = selectedResult else { return false }
        close()
        environment.jump(result)
        return true
    }

    private func read(_ candidate: RemoteTmuxFindWindowCandidate) async {
        guard textBytes < Self.maximumTextBytes else {
            unreadPaneCount += 1
            settledPaneCount += 1
            return
        }
        let text = await environment.readText(candidate)
        guard !Task.isCancelled else { return }
        settledPaneCount += 1
        guard let text else {
            unreadPaneCount += 1
            return
        }
        texts[candidate.id] = text
        textBytes += text.byteCount
        searchContents(of: candidate, text: text)
    }

    private func runSearch() {
        generation &+= 1
        searchTask?.cancel()
        paneSearchTasks.forEach { $0.cancel() }
        paneSearchTasks = []
        contentResults = [:]
        do {
            search = try RemoteTmuxFindWindowSearch(query: query, options: options)
            queryError = nil
        } catch {
            search = nil
            queryError = String(describing: error)
        }
        guard let search else {
            nameResults = []
            publish()
            return
        }
        nameResults = search.nameAndTitleResults(in: candidates)
        publish()
        guard !search.isEmpty, options.matchesContents, !texts.isEmpty else { return }
        let generation = generation
        let panes = candidates.compactMap { candidate in texts[candidate.id].map { (candidate, $0) } }
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var found: [RemoteTmuxFindWindowCandidate.ID: [RemoteTmuxFindWindowResult]] = [:]
            for (candidate, text) in panes {
                guard !Task.isCancelled else { return }
                found[candidate.id] = search.contentResults(for: candidate, text: text)
            }
            await self?.mergeContentResults(found, generation: generation)
        }
    }

    private func searchContents(of candidate: RemoteTmuxFindWindowCandidate, text: RemoteTmuxPaneText) {
        guard let search, !search.isEmpty, options.matchesContents else { return }
        let generation = generation
        paneSearchTasks.append(Task.detached(priority: .userInitiated) { [weak self] in
            let found = search.contentResults(for: candidate, text: text)
            guard !Task.isCancelled else { return }
            await self?.mergeContentResults([candidate.id: found], generation: generation)
        })
    }

    private func mergeContentResults(
        _ found: [RemoteTmuxFindWindowCandidate.ID: [RemoteTmuxFindWindowResult]],
        generation: Int
    ) {
        guard generation == self.generation else { return }
        contentResults.merge(found) { _, new in new }
        publish()
    }

    /// Names and titles first, then content hits in tab order, keeping the
    /// selection on the same result when it is still there.
    private func publish() {
        let selectedID = selectedResult?.id
        var merged = nameResults
        var contentCount = 0
        for candidate in candidates.sorted(by: { $0.order < $1.order }) {
            guard contentCount < RemoteTmuxFindWindowSearch.maximumContentHits,
                  let hits = contentResults[candidate.id] else { continue }
            let kept = hits.prefix(RemoteTmuxFindWindowSearch.maximumContentHits - contentCount)
            contentCount += kept.count
            merged.append(contentsOf: kept)
        }
        results = merged
        selectedIndex = selectedID.flatMap { id in merged.firstIndex { $0.id == id } } ?? 0
    }
}
