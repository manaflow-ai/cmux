public import Foundation
public import Observation

/// Drives the project picker: debounced server-side fuzzy search across the
/// Mac's directories, plus per-level browse listing.
///
/// While the Mac reports its directory index is still building, the model
/// re-polls the same query a few times so first-run searches fill in without
/// the user having to retype.
@MainActor
@Observable
public final class DispatchProjectPickerModel {
    public enum SearchState: Equatable {
        case idle
        case searching
        case results([DispatchDirectory], indexing: Bool, truncated: Bool)
        case failed
    }

    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }

    /// Whether browse levels include dot-directories.
    public var includeHidden = false

    public private(set) var searchState: SearchState = .idle

    private let service: any DispatchComposerServicing
    private let clock: any Clock<Duration>
    private var searchTask: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(200)
    private static let indexingRepollDelay: Duration = .milliseconds(900)
    /// First-run index builds on large home folders take tens of seconds;
    /// keep results filling in for a while before requiring another keystroke.
    private static let maxIndexingRepolls = 30

    public init(service: any DispatchComposerServicing, clock: any Clock<Duration> = ContinuousClock()) {
        self.service = service
        self.clock = clock
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = trimmedQuery
        guard !trimmed.isEmpty else {
            searchState = .idle
            return
        }
        searchState = .searching
        searchTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.debounce)
            } catch {
                return
            }
            await self?.runSearch(trimmed, repollsLeft: Self.maxIndexingRepolls)
        }
    }

    private func runSearch(_ query: String, repollsLeft: Int) async {
        do {
            let response = try await service.dispatchFSSearch(query: query)
            guard !Task.isCancelled, trimmedQuery == query else { return }
            searchState = .results(response.entries, indexing: response.indexing, truncated: response.truncated)
            if response.indexing, repollsLeft > 0 {
                do {
                    try await clock.sleep(for: Self.indexingRepollDelay)
                } catch {
                    return
                }
                guard !Task.isCancelled, trimmedQuery == query else { return }
                await runSearch(query, repollsLeft: repollsLeft - 1)
            }
        } catch {
            guard !Task.isCancelled, trimmedQuery == query else { return }
            searchState = .failed
        }
    }

    public func retrySearch() {
        scheduleSearch()
    }

    /// Load one browse level. Level views own the returned state; permission
    /// notices ride along in the success payload so the list stays usable.
    public func loadLevel(path: String) async -> Result<DispatchFSList, DispatchLaunchFailure> {
        do {
            let list = try await service.dispatchFSList(path: path, includeHidden: includeHidden)
            return .success(list)
        } catch let failure as DispatchLaunchFailure {
            return .failure(failure)
        } catch {
            return .failure(MobileShellComposite.dispatchLaunchFailure(from: error))
        }
    }

    public func cancelInFlightWork() {
        searchTask?.cancel()
    }
}
