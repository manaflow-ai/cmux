import Testing
@testable import CmuxTerminalCore

@Suite("ExternalHoverMailbox")
struct ExternalHoverMailboxTests {
    private static func token(_ seed: UInt64) -> HoverActivationTokenValue {
        HoverActivationTokenValue(bits: (seed, seed &+ 1, seed &+ 2, seed &+ 3))
    }

    private static func entry(_ seed: UInt64, event: UInt64 = 1, path: String = "/tmp/a") -> ExternalHoverMailbox.Entry {
        .init(event: event, token: token(seed), path: path)
    }

    // MARK: pending vs owner independence

    @Test("Recording pending never touches the accepted owner or revision")
    func pendingNeverTouchesOwner() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        let revisionAfterAccept = mailbox.ownerRevision
        let owner = mailbox.acceptedOwner

        mailbox.setPending(Self.entry(2))

        #expect(mailbox.acceptedOwner == owner)
        #expect(mailbox.ownerRevision == revisionAfterAccept)
        #expect(mailbox.pending == Self.entry(2))
    }

    @Test("Clearing pending never touches the accepted owner or revision")
    func clearingPendingNeverTouchesOwner() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        let revisionAfterAccept = mailbox.ownerRevision

        mailbox.setPending(Self.entry(2))
        mailbox.clearPending()

        #expect(mailbox.acceptedOwner == Self.entry(1))
        #expect(mailbox.ownerRevision == revisionAfterAccept)
        #expect(mailbox.pending == nil)
    }

    // MARK: owner mutations bump the revision

    @Test("acceptActive always bumps ownerRevision, even replacing an identical owner")
    func acceptActiveAlwaysBumps() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        let r1 = mailbox.ownerRevision
        mailbox.acceptActive(Self.entry(1))
        #expect(mailbox.ownerRevision == r1 + 1)
    }

    @Test("acceptActive replaces a different prior owner unconditionally")
    func acceptActiveReplacesPriorOwner() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        mailbox.acceptActive(Self.entry(2))
        #expect(mailbox.acceptedOwner == Self.entry(2))
    }

    @Test("inactive(token:) clears and bumps only when token is the current owner")
    func inactiveClearsOnlyCurrentOwner() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        let r1 = mailbox.ownerRevision

        // Stale token: idempotent success, no mutation.
        let staleResult = mailbox.inactive(token: Self.token(99))
        #expect(staleResult == true)
        #expect(mailbox.acceptedOwner == Self.entry(1))
        #expect(mailbox.ownerRevision == r1)

        // Current owner's token: clears and bumps.
        let currentResult = mailbox.inactive(token: Self.token(1))
        #expect(currentResult == true)
        #expect(mailbox.acceptedOwner == nil)
        #expect(mailbox.ownerRevision == r1 + 1)
    }

    @Test("inactive(token:) is idempotent once the owner has already moved on")
    func inactiveIdempotentAfterOwnerMovedOn() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        mailbox.acceptActive(Self.entry(2))
        let revisionAfterSecondAccept = mailbox.ownerRevision

        // A delayed inactive(1) arrives after the owner moved to 2: must not
        // clear 2, must return true, and must not bump the revision again
        // (nothing changed).
        let result = mailbox.inactive(token: Self.token(1))
        #expect(result == true)
        #expect(mailbox.acceptedOwner == Self.entry(2))
        #expect(mailbox.ownerRevision == revisionAfterSecondAccept)
    }

    @Test("teardown tombstones pending and owner and always bumps the revision")
    func teardownTombstonesEverything() {
        var mailbox = ExternalHoverMailbox()
        mailbox.acceptActive(Self.entry(1))
        mailbox.setPending(Self.entry(2))
        let r1 = mailbox.ownerRevision

        mailbox.teardown()

        #expect(mailbox.acceptedOwner == nil)
        #expect(mailbox.pending == nil)
        #expect(mailbox.ownerRevision == r1 + 1)
    }

    @Test("teardown bumps the revision even with no prior owner (unconditional tombstone)")
    func teardownBumpsWithNoPriorOwner() {
        var mailbox = ExternalHoverMailbox()
        let r0 = mailbox.ownerRevision
        mailbox.teardown()
        #expect(mailbox.ownerRevision == r0 + 1)
    }
}
