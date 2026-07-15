import CmuxBrowser
import Observation

/// Owns one markdown panel's find state and serializes DOM-find results.
@MainActor
@Observable
final class MarkdownFindController {
    private(set) var searchState: MarkdownSearchState?
    private(set) var focusRequestGeneration: UInt64 = 0
    private(set) var selectAllOnFocusRequest = false

    @ObservationIgnored private let service: BrowserFindService
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UInt64 = 0
    @ObservationIgnored private var lastNeedle = ""

    init(evaluator: any BrowserFindScriptEvaluating) {
        service = BrowserFindService(evaluator: evaluator)
    }

    func startFind() {
        let created = searchState == nil
        if created {
            searchState = MarkdownSearchState(needle: lastNeedle)
        }
        selectAllOnFocusRequest = created && !lastNeedle.isEmpty
        focusRequestGeneration &+= 1
        if created, !lastNeedle.isEmpty {
            _ = perform(.search(lastNeedle))
        }
    }

    func canApplyFocusRequest(_ generation: UInt64) -> Bool {
        generation != 0 &&
            generation == focusRequestGeneration &&
            searchState != nil
    }

    @discardableResult
    func updateNeedle(_ needle: String) -> Task<Void, Never>? {
        guard let searchState else { return nil }
        if searchState.needle != needle {
            searchState.needle = needle
        }
        searchState.selected = nil
        searchState.total = nil
        return perform(needle.isEmpty ? .clear : .search(needle))
    }

    @discardableResult
    func findNext() -> Task<Void, Never>? {
        guard searchState != nil else { return nil }
        return perform(.next)
    }

    @discardableResult
    func findPrevious() -> Task<Void, Never>? {
        guard searchState != nil else { return nil }
        return perform(.previous)
    }

    @discardableResult
    func hideFind() -> Task<Void, Never>? {
        guard let searchState else { return nil }
        lastNeedle = searchState.needle
        self.searchState = nil
        selectAllOnFocusRequest = false
        focusRequestGeneration &+= 1
        return perform(.clear)
    }

    func renderDidComplete() {
        guard let needle = searchState?.needle, !needle.isEmpty else { return }
        _ = perform(.search(needle))
    }

    func close() {
        activeTask?.cancel()
        activeTask = nil
        operationGeneration &+= 1
        searchState = nil
        focusRequestGeneration &+= 1
    }

    @discardableResult
    private func perform(_ operation: MarkdownFindOperation) -> Task<Void, Never> {
        activeTask?.cancel()
        operationGeneration &+= 1
        let generation = operationGeneration
        let state = searchState
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let matchCount: BrowserFindMatchCount?
            switch operation {
            case .search(let needle):
                matchCount = await service.search(needle: needle)
            case .next:
                matchCount = await service.next()
            case .previous:
                matchCount = await service.previous()
            case .clear:
                await service.clear()
                matchCount = nil
            }

            guard !Task.isCancelled,
                  generation == operationGeneration,
                  let matchCount,
                  searchState === state else { return }
            state?.total = matchCount.total
            state?.selected = matchCount.selected
        }
        activeTask = task
        return task
    }
}
