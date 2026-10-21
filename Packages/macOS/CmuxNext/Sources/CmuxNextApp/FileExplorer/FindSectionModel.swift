import Foundation
import Observation

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
    @ObservationIgnored private var generation = 0

    init(search: @escaping Search = FindSectionModel.ripgrep) {
        run = search
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
        root = folder
        generation += 1
        results = []
        state = .idle
    }

    /// Searches the root for `text` (fixed string, smart case); blank text clears the results.
    func search(_ text: String) async {
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
        guard mine == generation else { return }
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

    /// Opens a result's file in cmux when cmux shows its kind, else in its default app.
    static func open(_ match: RipgrepMatch, effects: any FileExplorerEffects) {
        let file = URL(fileURLWithPath: match.path)
        if !effects.openInCmux(file) { effects.openInDefaultApp(file) }
    }
}
