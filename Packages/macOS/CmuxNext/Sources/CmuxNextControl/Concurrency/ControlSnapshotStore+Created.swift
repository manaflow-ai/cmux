import CmuxNextDaemon

extension ControlSnapshotStore {
    /// How long a settled `action.run` waits for its created objects to show
    /// in a snapshot: the store can build a new object after the event that
    /// moved the sequence. Past it the reply lists what it shows (an object
    /// closed right away never shows).
    static let createdLimit: Duration = .seconds(2)
    /// Time left before the request's deadline for the reply to go out.
    static let replyMargin: Duration = .milliseconds(100)

    /// `settled`, or the first later snapshot that shows every object in
    /// `created`, so `action.run`'s `created` is not empty under load
    /// (plans/cmux-next/cli.md Remaining 13). Bounded by ``createdLimit`` and
    /// ends before `replyBy`, the request's own deadline: an object that never
    /// shows leaves it out of `created` instead of turning `ran` into a timeout.
    func showing(_ created: [ControlCreatedObject], after settled: ControlSnapshot,
                 replyBy: ContinuousClock.Instant) async -> ControlSnapshot {
        let showsAll: @Sendable (ControlSnapshot) -> Bool = { snapshot in
            created.allSatisfy { PublicIDTargetResolver.publicID(of: $0, in: snapshot.topology) != nil }
        }
        guard !showsAll(settled) else { return settled }
        let shown = await snapshot(where: showsAll, deadline: min(replyBy - Self.replyMargin, .now + Self.createdLimit))
        return shown ?? current
    }
}
