import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Foundation
import Testing

/// p06 sweep (group 333): the Hosted Chief migration waits for the Chief owner's connection with
/// ``ChiefConversationOwner/connection(supporting:)``, which the owner's attach answers, instead of an
/// observation task that re-read the owner on every change. A connection that serves the capability
/// answers at once; one that does not leaves the wait open; a cancelled wait ends with nil.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChiefOwnerConnectionWaitTests {
    static let capability = DaemonCapability.localConversations.rawValue

    private func owner() -> ChiefConversationOwner {
        let root = FileManager.default.temporaryDirectory.appending(path: "chief-owner-wait-\(UUID().uuidString)")
        return ChiefConversationOwner(home: ChiefHome(root: root, isolated: true))
    }

    private func connection() -> DaemonConnection {
        DaemonConnection(endpoint: DaemonEndpoint(socketPath: "/nonexistent/chief-owner-wait.sock"))
    }

    @Test func anAttachedOwnerAnswersAtOnce() async {
        let owner = owner()
        let attached = connection()
        owner.attach(attached, identity: DaemonIdentity(capabilities: [Self.capability], generation: "owner"))
        let answered = await owner.connection(supporting: Self.capability)
        #expect(answered === attached)
    }

    @Test func theAttachThatServesTheCapabilityAnswersTheWait() async {
        let owner = owner()
        let older = connection(), current = connection()
        // Main-actor tasks run in the order they were made: the wait is filed before the attaches.
        let wait = Task { @MainActor in await owner.connection(supporting: Self.capability) }
        let attaches = Task { @MainActor in
            #expect(owner.connectionWaitCount == 1)
            // An owner without the capability (an older build) does not answer it.
            owner.attach(older, identity: DaemonIdentity(capabilities: [], generation: "old"))
            #expect(owner.connectionWaitCount == 1)
            owner.attach(current, identity: DaemonIdentity(capabilities: [Self.capability], generation: "new"))
            #expect(owner.connectionWaitCount == 0)
        }
        await attaches.value
        #expect(await wait.value === current)
    }

    @Test func aCancelledWaitEndsWithNil() async {
        let owner = owner()
        let wait = Task { @MainActor in await owner.connection(supporting: Self.capability) }
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(owner.connectionWaitCount == 0)
    }

    @Test func aWaitCancelledWhileItWaitsLeavesNoWaiter() async {
        let owner = owner()
        // Main-actor tasks run in the order they were made: the wait is filed before the check.
        let wait = Task { @MainActor in await owner.connection(supporting: Self.capability) }
        let filed = Task { @MainActor in owner.connectionWaitCount }
        #expect(await filed.value == 1)
        wait.cancel()
        #expect(await wait.value == nil)
        #expect(owner.connectionWaitCount == 0)
        // A later owner with the capability finds no dead wait to answer.
        owner.attach(connection(), identity: DaemonIdentity(capabilities: [Self.capability], generation: "late"))
        #expect(owner.connectionWaitCount == 0)
    }
}
