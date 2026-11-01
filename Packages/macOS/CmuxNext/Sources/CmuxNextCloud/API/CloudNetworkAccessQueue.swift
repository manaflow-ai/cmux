public import Foundation

/// One read-then-write of a Cloud machine's network policy at a time, per machine (Internet
/// Access…, `cloud set-network-access`). The app's cloud service owns the one instance.
@MainActor
public final class CloudNetworkAccessQueue {
    /// The newest read-then-write per machine; the next one waits for it.
    private var tails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    public init() {}

    /// Runs `body` after every earlier one for `machineID` has ended, so two runs from this app
    /// never both judge (widening included) the same stale policy and the later PUT undoes the
    /// earlier one. Runs for different machines do not wait for each other. The server takes no
    /// conditional PUT yet; edits from elsewhere can still cross.
    public func serialized<T: Sendable>(_ machineID: String,
                                        _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tails[machineID]?.task
        // task-owner: this run's read-then-write; the caller awaits it below.
        let run = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await body()
        }
        let id = UUID()
        // task-owner: the queue's tail; it ends when this run does, whatever its answer.
        tails[machineID] = (id, Task { @MainActor in _ = try? await run.value })
        defer { if tails[machineID]?.id == id { tails[machineID] = nil } }
        return try await run.value
    }

    /// Whether a run for `machineID` is queued or running (tests).
    public func isBusy(_ machineID: String) -> Bool { tails[machineID] != nil }
}
