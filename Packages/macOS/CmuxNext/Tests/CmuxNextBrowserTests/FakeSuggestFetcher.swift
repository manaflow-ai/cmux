@testable import CmuxNextBrowser
import Foundation
import Synchronization

/// A suggest endpoint the test answers by hand. Each fetch waits until
/// `respond` or its task is cancelled (counted in `cancellations`).
nonisolated final class FakeSuggestFetcher: OmniboxSuggestFetching {
    struct Request: Equatable {
        var url: URL
        var ephemeral: Bool
    }

    private struct Pending {
        var id: Int
        var continuation: CheckedContinuation<Data, any Error>
    }

    private struct State {
        var nextID = 0
        var requests: [Request] = []
        var pending: [Pending] = []
        var cancellations = 0
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = Mutex(State())

    var requests: [Request] { state.withLock { $0.requests } }
    var cancellations: Int { state.withLock { $0.cancellations } }

    func fetch(_ url: URL, ephemeral: Bool) async throws -> Data {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let ready: [CheckedContinuation<Void, Never>]? = state.withLock { state in
                    state.requests.append(Request(url: url, ephemeral: ephemeral))
                    if Task.isCancelled {
                        state.cancellations += 1
                        return nil
                    }
                    state.pending.append(Pending(id: id, continuation: continuation))
                    let count = state.requests.count
                    let ready = state.waiters.filter { $0.count <= count }.map(\.continuation)
                    state.waiters.removeAll { $0.count <= count }
                    return ready
                }
                guard let ready else { return continuation.resume(throwing: CancellationError()) }
                ready.forEach { $0.resume() }
            }
        } onCancel: {
            let cancelled = state.withLock { state -> Pending? in
                guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return nil }
                state.cancellations += 1
                return state.pending.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Answers the oldest open request.
    func respond(_ data: Data) {
        let first = state.withLock { state -> Pending? in state.pending.isEmpty ? nil : state.pending.removeFirst() }
        first?.continuation.resume(returning: data)
    }

    /// An OpenSearch response.
    static func openSearch(_ query: String, _ suggestions: [String]) -> Data {
        (try? JSONSerialization.data(withJSONObject: [query, suggestions] as [Any])) ?? Data()
    }

    /// Returns once at least `count` requests were made.
    func requests(atLeast count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.requests.count >= count { return true }
                state.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
