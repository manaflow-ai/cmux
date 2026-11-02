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

    /// `cloud set-network-access`'s change of `machineID` to `access`, after every earlier run for it
    /// (``serialized(_:_:)``). It reads the stored policy, changes only its mode (and, for `trusted`,
    /// adds the server's presets), and writes it back, so the machine's own ranges and domains stay.
    /// The same policy is written again unless it is applied: a PUT retries a failed apply. Returns
    /// the state the server holds after the run.
    ///
    /// `refusal` (an agent's run) is thrown for any level but `none`: the PUT replaces the policy
    /// unconditionally, so a level judged against a read that a person's newer edit (the dashboard,
    /// another Mac) made stale could reopen what they closed. `none` is the narrowest whatever the
    /// server holds by then. Lifting this needs a conditional PUT on the server (#28706).
    public func set(_ access: CloudNetworkAccess, on machineID: String, refusal: (any Error)?,
                    read: @escaping @MainActor (String) async throws -> CloudNetworkPolicyState,
                    write: @escaping @MainActor (String, CloudNetworkPolicy) async throws -> CloudNetworkPolicyState)
        async throws -> CloudNetworkPolicyState {
        try await serialized(machineID) {
            if let refusal, access != .noInternet { throw refusal }
            let current = try await read(machineID)
            let policy = access.applied(to: current.policy, presets: current.presets.map(\.id))
            if policy == current.policy, current.applied?.state == "applied" { return current }
            return try await write(machineID, policy)
        }
    }

    /// Whether a run for `machineID` is queued or running (tests).
    public func isBusy(_ machineID: String) -> Bool { tails[machineID] != nil }
}
