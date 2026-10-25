import CmuxNextActions
import Foundation
import Observation
import CmuxNextFilesUI

/// The right sidebar's Find section and the Find pane (classic's project-wide
/// find): ripgrep over a folder (``RipgrepSearch``, the flags classic ran),
/// one result per matching line. A newer search drops an older one's answer.
@MainActor
@Observable
final class FindSectionModel {
    enum State: Equatable, Sendable {
        case idle
        case searching
        /// `limited`: ripgrep stopped at ``RipgrepSearch/limit`` matches.
        case done(limited: Bool)
        case failed(String)
    }

    /// Runs one search; nil when ripgrep is not installed.
    typealias Search = @MainActor (_ query: String, _ root: String) async -> RipgrepSearch.Outcome?

    /// The folder searched; nil before ``setRoot(_:)``.
    private(set) var root: URL?
    private(set) var query = ""
    private(set) var results: [RipgrepMatch] = []
    private(set) var state: State = .idle

    @ObservationIgnored private let run: Search
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var generation = 0
    /// The waiting or running search of ``type(_:)``; the next keystroke cancels it.
    @ObservationIgnored private(set) var pendingSearch: Task<Void, Never>?

    /// How long typing pauses before a live search starts.
    static let debounce: Duration = .milliseconds(250)

    /// - Parameter clock: times the typing pause; tests pass a manual clock.
    init(search: @escaping Search = FindSectionModel.ripgrep, clock: any Clock<Duration> = ContinuousClock()) {
        run = search
        self.clock = clock
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // Each handle here is Sendable and stops from any thread: a release off main cleans up too.
    nonisolated deinit {
        pendingSearch?.cancel()
    }

    /// The search field's text changed: cancels the waiting or running search (ripgrep stops)
    /// and searches for `text` once typing pauses for ``debounce``.
    func type(_ text: String) {
        pendingSearch?.cancel()
        query = text
        let clock = clock
        pendingSearch = Task { [weak self] in
            do {
                // concurrency-allow: a bounded, cancellable typing pause (injected clock); the next keystroke cancels it.
                // wakeup-allow: runs only after a keystroke in the Find field, never while idle.
                try await clock.sleep(for: Self.debounce, tolerance: nil)
            } catch {
                return
            }
            await self?.perform(text)
        }
    }

    /// The App's search: the installed `rg`, off the main actor.
    static let ripgrep: Search = { query, root in
        guard let rg = RipgrepSearch.executable() else { return nil }
        return await RipgrepSearch.run(rg, query: query, root: root)
    }

    /// Searches `folder` from now on; a new folder clears the old results.
    func setRoot(_ folder: URL) {
        let folder = folder.standardizedFileURL
        guard folder != root else { return }
        pendingSearch?.cancel()
        pendingSearch = nil
        root = folder
        generation += 1
        results = []
        state = .idle
    }

    /// Searches the root for `text` (fixed string, smart case); blank text clears the results.
    func search(_ text: String) async {
        pendingSearch?.cancel()
        pendingSearch = nil
        await perform(text)
    }

    /// One search for `text`; a newer search (or a cancel) drops its answer.
    private func perform(_ text: String) async {
        query = text
        generation += 1
        let mine = generation
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root, !trimmed.isEmpty else {
            results = []
            state = .idle
            return
        }
        state = .searching
        let outcome = await run(trimmed, root.path)
        guard mine == generation, !Task.isCancelled else { return }
        switch outcome {
        case nil:
            results = []
            state = .failed(FindInDirectoryStrings.ripgrepMissing)
        case .failed(let status)?:
            results = []
            state = .failed(FindInDirectoryStrings.ripgrepExited(status))
        case .matches(let matches, let limited)?:
            results = matches
            state = .done(limited: limited)
        }
    }

    /// Opens a result's file in cmux at the matching line and column when cmux shows its kind,
    /// else in its default app.
    static func open(_ match: RipgrepMatch, effects: any FileExplorerEffects) {
        let file = URL(fileURLWithPath: match.path)
        if !effects.openInCmux(file, at: FileLineLocation(line: match.line, column: match.column)) { effects.openInDefaultApp(file) }
    }
}
