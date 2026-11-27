import Foundation

/// What a reader keeps from the daemon's feed views (the phone's Needs you set, Home's notices)
/// belongs to one account: the view's ``FeedDaemonView/owner``. A view of another account, loaded
/// or not, or a signed-out one, forgets it at once (manaflow-ai/cmux#37378 review: A's requests
/// reached B's phones); a disconnect of the same account keeps it, since that view is not settled.
/// `Value` is what the reader derives from a settled view (nil: nothing to hand on yet).
package nonisolated struct FeedAccountProjection<Value: Equatable & Sendable>: Sendable {
    /// One step for the reader to take.
    package enum Step: Equatable, Sendable {
        /// Forget what was kept, sending nothing: an empty set would close the last account's
        /// requests on the next account's devices.
        case forget
        /// Hand on `value`, derived from `user`'s feed.
        case send(Value, user: String)
    }

    /// The account the kept value belongs to (the view's `account.id`), nil signed out.
    package private(set) var account: String?
    /// The value last handed on for ``account``.
    package private(set) var sent: Value?

    package init() {}

    /// The steps `view` asks for; `derive` reads a settled view of the current account.
    package mutating func apply(_ view: FeedDaemonView, derive: (FeedDaemonView) -> Value?) -> [Step] {
        var steps: [Step] = []
        if view.owner != account {
            if account != nil || sent != nil { steps.append(.forget) }
            (account, sent) = (view.owner, nil)
        }
        guard let owner = view.owner, view.isSettled, let value = derive(view), value != sent else { return steps }
        sent = value
        steps.append(.send(value, user: view.account?.user ?? owner))
        return steps
    }

    /// Whether `view` may replace what its reader shows (it is settled). A view of another account
    /// than the last one seen that is not settled yet calls `clear` first: the reader's last
    /// account's rows go at once, before the new account's snapshot.
    package mutating func settled(_ view: FeedDaemonView, clear: () -> Void) -> Bool {
        if view.owner != account {
            (account, sent) = (view.owner, nil)
            if !view.isSettled { clear() }
        }
        return view.isSettled
    }
}

extension FeedAccountProjection {
    /// Runs a projection over `feed`'s `layout` view, read again on each feed change, until the
    /// task is cancelled: each set `derive` reads goes to `send` (with its account's user), and
    /// another account's view or a sign-out calls `forget` at once.
    @MainActor package static func follow(_ feed: FeedDaemonClient, _ layout: FeedDaemonView.Layout, derive: (FeedDaemonView) -> Value?,
                                          send: (Value, String) async -> Void, forget: () async -> Void) async {
        var projection = Self()
        for await _ in feed.changes() {
            guard let view = try? await feed.view(layout), !Task.isCancelled else { continue }
            for step in projection.apply(view, derive: derive) {
                if case let .send(value, user) = step { await send(value, user) } else { await forget() }
            }
        }
    }
}
