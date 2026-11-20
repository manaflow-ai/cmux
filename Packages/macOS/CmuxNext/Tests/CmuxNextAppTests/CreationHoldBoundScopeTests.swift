import CmuxNextActions
@testable import CmuxNextFocusUI
import Foundation
import Testing

/// A creation hold's bounds (its reply bound and its limit) end the hold in a turn of their own, never inside the
/// task-local values of the run that opened the hold (review of #35874, finding 2). A bound that inherited them ran the
/// held keys again under that run's scope: under a menu pick's mark (`ActionRunScope.menuPick`) a find field's responder
/// report of a held Cmd-F counted as the person's focus choice, and under a CLI run's scope a held key's view change was
/// judged as the CLI's (`ActionRunScope.viewChangeAllowed`). The hold's other turn, its flush, detaches the same way.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CreationHoldBoundScopeTests {
    /// What the bound saw when it ended the hold.
    @MainActor private final class Seen {
        var bound: CreationInputBuffer.Bound?
        var scope: ActionRunScope?
    }

    private static func ended(_ seen: Seen, within limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while seen.bound == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// The reply bound of a creation opened inside a person's run (a menu pick, a key) ends the hold with no run scope.
    @Test func theReplyBoundEndsTheHoldOutsideTheRunThatOpenedIt() async throws {
        let buffer = CreationInputBuffer(began: .now)
        buffer.replyWaitLimit = .milliseconds(100)
        let seen = Seen()
        buffer.onBound = { _, bound in (seen.bound, seen.scope) = (bound, ActionRunScope.current) }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .user, allowsViewChange: true)) {
            _ = buffer.open(generation: 1, newWorkspace: true)
        }
        try await Self.ended(seen, within: .seconds(5))
        #expect(seen.bound == .reply, "the reply bound did not end the hold")
        #expect(seen.scope == nil, "the reply bound ended the hold inside the opening run's scope: \(String(describing: seen.scope))")
    }

    /// The limit of a hold armed inside a CLI run ends the hold with no run scope.
    @Test func theLimitEndsTheHoldOutsideTheRunThatArmedIt() async throws {
        let buffer = CreationInputBuffer(began: .now)
        let seen = Seen()
        buffer.onBound = { _, bound in (seen.bound, seen.scope) = (bound, ActionRunScope.current) }
        ActionRunScope.$current.withValue(ActionRunScope(origin: .cli, allowsViewChange: false)) {
            buffer.expire(after: .milliseconds(100))
        }
        try await Self.ended(seen, within: .seconds(5))
        #expect(seen.bound == .limit, "the limit did not end the hold")
        #expect(seen.scope == nil, "the limit ended the hold inside the arming run's scope: \(String(describing: seen.scope))")
    }
}
