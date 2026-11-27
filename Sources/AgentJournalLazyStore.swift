import CmuxAgentJournal
import Foundation
import os

/// Open-once gate for the agent journal store, so opening the SQLite journal
/// (including its rare, potentially expensive open-time retention prune)
/// never runs on the main thread: the main-actor callers of the lifecycle
/// center only enqueue operations, while the store itself is first opened by
/// whichever off-main caller needs it — the socket worker's append or the
/// journal consumer task.
final class AgentJournalLazyStore: Sendable {
    private enum State {
        case unopened(URL)
        case opened(AgentJournalStore)
        case unavailable
    }

    // Lock justification: an open-once compare-and-set from non-async
    // callers (socket worker thread and the consumer task); the guarded
    // section is one bounded SQLite open + migration.
    private let state: OSAllocatedUnfairLock<State>

    init(databaseURL: URL) {
        self.state = OSAllocatedUnfairLock(initialState: .unopened(databaseURL))
    }

    /// The opened store, opening it on first use. Returns `nil` (and reports
    /// the failure once on the event bus) when the journal cannot open.
    func store() -> AgentJournalStore? {
        // withLockUnchecked: the store class is Sendable and nothing else
        // escapes the critical section.
        state.withLockUnchecked { current in
            switch current {
            case .opened(let store):
                return store
            case .unavailable:
                return nil
            case .unopened(let url):
                do {
                    let store = try AgentJournalStore(databaseURL: url)
                    current = .opened(store)
                    return store
                } catch {
                    current = .unavailable
                    CmuxEventBus.shared.publish(
                        name: "agent.journal.open_failed",
                        category: "agent",
                        source: "journal",
                        payload: ["error": String(describing: error)]
                    )
                    return nil
                }
            }
        }
    }

    /// Closes the store if it was opened.
    func close() {
        state.withLockUnchecked { current in
            if case .opened(let store) = current {
                store.close()
            }
            current = .unavailable
        }
    }
}
