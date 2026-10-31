public import CmuxNextActions
public import CmuxNextCloud

/// HQ #4884 ("Signed-out cloud is text only"): a person's run of a Cloud action that is
/// unavailable only because nobody is signed in signs in, then runs the action, the way New
/// Cloud Machine resumes after sign-in (#27104). The CLI, MCP, scripts and pages still get
/// ``CloudStrings/signInFirst``. The App gives it the Cloud service's reads (CloudHandlers).
@MainActor
public struct CloudSignInRecovery {
    /// Actions whose signed-out reason gets no recovery: running them after a sign-in means
    /// nothing (Sign Out) or the sign-in already chose for them (Switch Active Team).
    public nonisolated static let exempt: Set<ActionID> = ["palette.auth.signOut", "openTeamPicker"]

    /// One pending replay, shared with New Cloud Machine's: a later intent, a sign-out or a
    /// team change drops the earlier one (``CloudSignedOutCreationContinuation``).
    let pending: CloudSignedOutCreationContinuation
    let signIn: @MainActor () async -> Bool
    /// A machine list read for this account within the last 30 s (`CloudService.hasCurrentList`).
    let hasCurrentList: @MainActor () -> Bool
    let isSignedIn: @MainActor () -> Bool
    /// A fresh machine list read; false when it failed or a newer read superseded it.
    let refresh: @MainActor () async -> Bool

    public init(pending: CloudSignedOutCreationContinuation, signIn: @escaping @MainActor () async -> Bool,
                hasCurrentList: @escaping @MainActor () -> Bool, isSignedIn: @escaping @MainActor () -> Bool,
                refresh: @escaping @MainActor () async -> Bool) {
        (self.pending, self.signIn, self.hasCurrentList, self.isSignedIn, self.refresh) = (pending, signIn, hasCurrentList, isSignedIn, refresh)
    }

    /// Whether a person's run of `id`, unavailable for `reason`, signs in and then runs it.
    public nonisolated static func recovers(_ id: ActionID, reason: String) -> Bool {
        reason == CloudStrings.signInFirst && !exempt.contains(id)
    }

    public func bind(into registry: ActionRegistry) {
        registry.unavailableRecoveries.append { [weak registry, self] id, reason in
            guard Self.recovers(id, reason: reason) else { return nil }
            return ActionRecovery(note: CloudStrings.signInToContinue) { id, invocation in
                let expected = pending.reserve()
                // task-owner: the reserved generation owns the replay; a later intent, sign-out or team change cancels it.
                Task { @MainActor in
                    // The machine list loads after sign-in; a machine action replayed before it lands finds no machine.
                    await pending.perform(expected: expected, signIn: {
                        guard await signIn() else { return false }
                        // A list read for this account, else a fresh read; one a newer read superseded (the
                        // sign-in's own refresh) is read once more. A failed read still replays, so the action
                        // reports its own error instead of nothing.
                        for _ in 0..<2 where !hasCurrentList() && isSignedIn() {
                            if await refresh() { break }
                        }
                        return true
                    }, resume: {
                        guard let registry, isSignedIn() else { return }
                        Self.resume(id, invocation, in: registry)
                    })
                }
            }
        }
    }

    /// Runs `id` for the person once signed in; a reason that still holds (no team, no backend) is reported.
    public static func resume(_ id: ActionID, _ invocation: ActionInvocation, in registry: ActionRegistry) {
        if let reason = registry.unavailableReason(for: id) {
            registry.refuse(reason)
            return
        }
        registry.perform(id, invocation: invocation)
    }
}
