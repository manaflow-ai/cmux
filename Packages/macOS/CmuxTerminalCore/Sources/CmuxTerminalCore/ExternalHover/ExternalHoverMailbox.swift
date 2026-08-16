import Foundation

/// Opaque mirror of Ghostty's `HoverActivationToken` (`[4]u64`). Never
/// interpreted or hashed further — only ever compared for equality, and
/// carried verbatim to `ghostty_surface_clear_external_link_hover`.
public struct HoverActivationTokenValue: Sendable, Equatable {
    public let bits: (UInt64, UInt64, UInt64, UInt64)

    public init(bits: (UInt64, UInt64, UInt64, UInt64)) {
        self.bits = bits
    }

    public static func == (lhs: HoverActivationTokenValue, rhs: HoverActivationTokenValue) -> Bool {
        lhs.bits == rhs.bits
    }

    /// All-zero is Ghostty's own sentinel for "no token" / setter failure —
    /// never a value a real mint can produce.
    public static let zero = HoverActivationTokenValue(bits: (0, 0, 0, 0))
}

/// (B) ExternalHover — the host-owned "logical acceptance" mailbox for one
/// surface. A plain value type: every mutation is a pure transition with no
/// side effects, no locking, and no Ghostty API calls of its own — the
/// caller (`ExternalHoverOwnerCoordinator`) is responsible for guarding
/// access with a lock and for never calling into Ghostty or dispatching to
/// the main thread while holding that lock.
///
/// `performAction == true` from Ghostty's activation ack means *synchronous
/// acceptance into host logical ownership* — not merely "enqueued". Only an
/// owner mutation (`acceptActive`, a successful `inactive`, or `teardown`)
/// bumps `ownerRevision`; recording or clearing `pending` alone never does,
/// so a stale event's queued projection task can never resurrect a display
/// that a newer event has already replaced or cleared — see
/// `ExternalHoverOwnerCoordinator`'s projection check.
public struct ExternalHoverMailbox: Sendable, Equatable {
    /// One candidate: the host-generated hover event this candidate belongs
    /// to, the activation token Ghostty minted for it, and the resolved
    /// local path it represents.
    public struct Entry: Sendable, Equatable {
        public let event: UInt64
        public let token: HoverActivationTokenValue
        public let path: String

        public init(event: UInt64, token: HoverActivationTokenValue, path: String) {
            self.event = event
            self.token = token
            self.path = path
        }
    }

    /// Not-yet-accepted candidate. Replacing this alone is not an owner
    /// mutation — it never advances `ownerRevision`.
    public private(set) var pending: Entry?

    /// The currently accepted owner, if any. `nil` means no override is
    /// displayed. Mutating this field (to a new owner or back to `nil`) is
    /// the ONLY thing that advances `ownerRevision`.
    public private(set) var acceptedOwner: Entry?

    /// Bumped only by an owner mutation (never by a pending-only change).
    /// A main-thread projection task captured at `ownerRevision == r` is
    /// valid only as long as the mailbox's current revision is still `r`.
    public private(set) var ownerRevision: UInt64 = 0

    public init() {}

    /// Records a new pending candidate. Never mutates `acceptedOwner` or
    /// `ownerRevision` — a pending-only change must never invalidate an
    /// existing owner's queued projection task.
    public mutating func setPending(_ entry: Entry) {
        pending = entry
    }

    /// Clears the pending candidate without touching the accepted owner.
    /// Returns whatever was cleared (`nil` if nothing was pending) — (C)
    /// diagnostics' `withdrawUnconditionally` uses this to release a still-
    /// armed render demand for the cleared entry's event even when it never
    /// reached `acceptedOwner`.
    @discardableResult
    public mutating func clearPending() -> Entry? {
        let cleared = pending
        pending = nil
        return cleared
    }

    /// Synchronous acceptance into host logical ownership: the entry becomes
    /// the accepted owner (replacing any prior owner) and `ownerRevision`
    /// advances. Also clears `pending` if it was this same entry (it's now
    /// the owner, not merely pending).
    ///
    /// Per final-spec's destructive-invalidation requirement, this is the
    /// ONLY way a new owner is ever installed — there is no pending-only
    /// path that later "promotes" without going through here.
    @discardableResult
    public mutating func acceptActive(_ entry: Entry) -> Bool {
        if pending?.token == entry.token {
            pending = nil
        }
        acceptedOwner = entry
        ownerRevision += 1
        return true
    }

    /// Idempotent inactive semantics: if `token` is the current accepted
    /// owner, clears it (an owner mutation to `nil`, advancing
    /// `ownerRevision`) and returns `true`. If `token` is NOT the current
    /// owner (already replaced or already cleared), the postcondition
    /// "`token` is not owner" already holds, so this returns `true` as an
    /// idempotent success WITHOUT touching whatever newer owner is
    /// installed — this is what lets a stale core-side inactive retry
    /// terminate without racing a newer accept.
    @discardableResult
    public mutating func inactive(token: HoverActivationTokenValue) -> Bool {
        guard let current = acceptedOwner, current.token == token else {
            return true
        }
        acceptedOwner = nil
        ownerRevision += 1
        return true
    }

    /// Explicit clear regardless of which token currently owns — used when
    /// the host itself decides to withdraw (e.g. cwd change, nil candidate,
    /// Cmd released). Always an owner mutation to `nil` if an owner was
    /// present; a no-op (no revision bump) if there already was none, since
    /// there is nothing to invalidate.
    @discardableResult
    public mutating func clearOwnerUnconditionally() -> Entry? {
        guard let previous = acceptedOwner else { return nil }
        acceptedOwner = nil
        ownerRevision += 1
        return previous
    }

    /// Surface teardown (detach/deinit): tombstones both `pending` and
    /// `acceptedOwner` and advances `ownerRevision` unconditionally, so any
    /// queued projection task for this surface is invalidated even if there
    /// was no owner to begin with (the revision bump itself is the
    /// tombstone signal, independent of what was previously stored).
    public mutating func teardown() {
        pending = nil
        acceptedOwner = nil
        ownerRevision += 1
    }
}
