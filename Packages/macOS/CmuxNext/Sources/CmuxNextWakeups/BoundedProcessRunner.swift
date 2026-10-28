import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// A ``ProcessRunning`` that runs at most `atOnce` requests of its base runner at a time; the others wait in
/// arrival order. The bound is the instance's, shared by every copy, so one runner made at the composition root
/// bounds every caller it is passed to, however many of them there are (the App's one `gh` runner: two at once
/// for every chat's pull request chip, the sidebar and the reply cards). Chrome bounds connections the same way:
/// one socket pool per profile caps the sockets to a host for every requester, and queues the rest in priority
/// order (net/socket/client_socket_pool_manager.cc, `max_sockets_per_group`).
///
/// ```swift
/// let gitHubCLI = BoundedProcessRunner(AsyncProcess(), atOnce: 2)
/// let reader = AgentChatPullRequestReader(processes: gitHubCLI)
/// ```
public struct BoundedProcessRunner: ProcessRunning {
    private let base: any ProcessRunning
    private let slots: ProcessSlots

    /// - Parameters:
    ///   - base: what runs each request.
    ///   - atOnce: the most requests running together; at least 1.
    public init(_ base: any ProcessRunning, atOnce: Int) {
        self.base = base
        slots = ProcessSlots(count: max(1, atOnce))
    }

    /// Waits for a free slot, then runs `request` on the base runner; the slot passes on when the run ends,
    /// whether it returned or threw.
    public func outcome(of request: ProcessRequest) async throws -> ProcessOutcome {
        await slots.acquire()
        let result: Result<ProcessOutcome, any Error>
        do {
            result = .success(try await base.outcome(of: request))
        } catch {
            result = .failure(error)
        }
        await slots.release()
        return try result.get()
    }
}

/// A fixed number of slots, handed out in arrival order.
private actor ProcessSlots {
    private var free: Int
    private var waiting: [OnceContinuation<Void, OnceContinuationError>] = []

    init(count: Int) {
        free = count
    }

    func acquire() async {
        guard free == 0 else {
            free -= 1
            return
        }
        // The waiter waits in arrival order until release() hands it the slot.
        try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in waiting.append(waiter) }
    }

    /// The slot passes to the first waiter, or back to the free ones.
    func release() {
        guard waiting.isEmpty else {
            waiting.removeFirst().resume(returning: ())
            return
        }
        free += 1
    }
}
