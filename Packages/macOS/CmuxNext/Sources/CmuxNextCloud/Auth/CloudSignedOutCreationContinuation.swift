/// Owns one person-initiated creation while hosted Cloud sign-in is pending.
/// Replacement, sign-out, and policy changes invalidate the previous generation.
@MainActor
public final class CloudSignedOutCreationContinuation {
    private var generation = 0
    private var pendingGeneration: Int?

    public init() {}

    /// Reserves one replay generation synchronously, before an action hands its
    /// asynchronous sign-in work to ActionRegistry.
    public func reserve() -> Int {
        cancel()
        pendingGeneration = generation
        return generation
    }

    /// Completes a reserved sign-in. The registry owns cancellation of this
    /// operation; a stale generation can never replay the captured creation.
    @discardableResult
    public func perform(
        expected: Int,
        signIn: @escaping @MainActor () async -> Bool,
        resume: @escaping @MainActor () -> Void
    ) async -> Bool {
        guard pendingGeneration == expected, generation == expected, !Task.isCancelled else {
            cancel(expected: expected)
            return false
        }
        let succeeded = await signIn()
        guard pendingGeneration == expected, generation == expected else { return false }
        pendingGeneration = nil
        guard succeeded, !Task.isCancelled else {
            generation += 1
            return false
        }
        // Consume before calling out; replay may itself start another intent.
        generation += 1
        resume()
        return true
    }

    /// Hosted auth publishes its user before loading the initial active team.
    /// That nil-to-team hydration belongs to the sign-in we are awaiting.
    /// A later user replacement, sign-out, or populated-team change does not.
    public func scopeDidChange(from previous: [String?], to current: [String?]) {
        guard isPending else { return }
        struct Request: Encodable { var previous: [String?], current: [String?] }
        struct Reply: Decodable { var survives: Bool }
        // Rust's `creation_survives_scope_change`; an FFI that does not answer cancels (never replays across accounts).
        if CloudStartCore().call("cloud_auth_creation_scope", Request(previous: previous, current: current), as: Reply.self)?.survives == true {
            return
        }
        cancel()
    }

    public func cancel() {
        generation += 1
        pendingGeneration = nil
    }

    public func cancel(expected: Int) {
        guard pendingGeneration == expected, generation == expected else { return }
        cancel()
    }

    public var isPending: Bool { pendingGeneration != nil }
}
