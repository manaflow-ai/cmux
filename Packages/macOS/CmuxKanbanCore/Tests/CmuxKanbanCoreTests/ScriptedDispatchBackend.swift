import Foundation

@testable import CmuxKanbanCore

/// A test ``DispatchBackend`` that replays a fixed script of progress events.
///
/// When `finishes` is true the stream emits the script and completes (modelling
/// a run that ends on its own). When false the stream stays open after the
/// script so a test can exercise ``KanbanEngine/cancel(cardId:)`` against a
/// still-running card; ``cancel(_:)`` then finishes the open stream.
actor ScriptedDispatchBackend: DispatchBackend {
    private let script: [KanbanDispatchProgress]
    private let finishes: Bool
    private var open: [KanbanDispatchHandle: AsyncStream<KanbanDispatchProgress>.Continuation] = [:]
    private(set) var cancelledHandles: [KanbanDispatchHandle] = []

    init(script: [KanbanDispatchProgress], finishes: Bool = true) {
        self.script = script
        self.finishes = finishes
    }

    func dispatch(card: KanbanCard, workingDirectory: String?) async throws -> KanbanDispatchSession {
        let handle = KanbanDispatchHandle(cardId: card.id)
        var continuation: AsyncStream<KanbanDispatchProgress>.Continuation!
        let stream = AsyncStream<KanbanDispatchProgress> { continuation = $0 }
        for event in script { continuation.yield(event) }
        if finishes {
            continuation.finish()
        } else {
            open[handle] = continuation
        }
        return KanbanDispatchSession(handle: handle, progress: stream)
    }

    func cancel(_ handle: KanbanDispatchHandle) async {
        cancelledHandles.append(handle)
        open[handle]?.finish()
        open[handle] = nil
    }

    func cancelledCount() -> Int { cancelledHandles.count }
}

/// A test ``DispatchBackend`` whose ``dispatch(card:workingDirectory:)`` always
/// throws, modelling a run that cannot start at all (e.g. the agent executable
/// cannot be resolved). Exercises ``KanbanEngine``'s start-failure path.
struct ThrowingDispatchBackend: DispatchBackend {
    struct DispatchError: Error, CustomStringConvertible {
        var description: String { "could not start" }
    }

    func dispatch(card: KanbanCard, workingDirectory: String?) async throws -> KanbanDispatchSession {
        throw DispatchError()
    }

    func cancel(_ handle: KanbanDispatchHandle) async {}
}
