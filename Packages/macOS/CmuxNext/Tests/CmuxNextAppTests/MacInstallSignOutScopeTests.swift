import CmuxNextCloud
import Foundation
import Testing

@Suite struct MacInstallSignOutScopeTests {
    private func make(_ owner: MacSignOutOwner, root: URL) -> MacInstallIdentity {
        MacInstallIdentity(store: .files(directory: root), transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
    }

    @Test func retiringAnOldAccountPreservesTheCurrentAccountsClientAndKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacSignOutOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        let a = try #require(await identity.installID())
        let keyA = try #require(await owner.a.publicKey(a))
        try await identity.signedIn(stackUser: "stack_b", session: { "session-b" })
        let b = try #require(await identity.installID())
        let tokenB = try await identity.installToken()
        await identity.signOut(stackUser: "stack_a", session: { "session-a" })
        #expect(await identity.installID() == b)
        #expect(await owner.a.revoked == [a])
        #expect(await owner.b.revoked.isEmpty)
        do {
            #expect(try await identity.installToken() == tokenB)
            await identity.invalidate()
            _ = try await identity.installToken() // Owner verifies B still uses its original registered key.
        } catch { Issue.record("Retiring A discarded B's live install: \(error)") }
        await identity.unbind()
        try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        let replacement = try #require(await identity.installID())
        #expect(replacement != a)
        #expect(await owner.a.publicKey(replacement) != keyA)
    }

    @Test func anotherAccountCanBindWhileTheOriginalRevokeIsHeld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacSignOutOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        await owner.a.holdNextRevoke()
        let ending = Task { await identity.signOut(stackUser: "stack_a", session: { "session-a" }) }
        defer { Task { await owner.a.release() } }
        await owner.a.waitUntilHeld()
        do { try await identity.signedIn(stackUser: "stack_b", session: { "session-b" }) }
        catch { Issue.record("A's revoke blocked a different account: \(error)") }
        let b = await identity.installID()
        #expect(b?.hasPrefix("inst_b_") == true)
        await owner.a.release()
        await ending.value
        #expect(await identity.installID() == b)
        await identity.invalidate()
        do { _ = try await identity.installToken() }
        catch { Issue.record("Finishing A's revoke invalidated B: \(error)") }
        #expect(await owner.b.registrations == 1)
        #expect(await owner.b.revoked.isEmpty)
    }

    @Test func unbindingCannotReopenTheOriginalAccountBeforeItsKeyRotationFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacSignOutOwner(), identity = make(owner, root: root)
        try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        let old = try #require(await identity.installID())
        await owner.a.holdNextRevoke()
        let ending = Task { await identity.signOut(stackUser: "stack_a", session: { "session-a" }) }
        defer { Task { await owner.a.release() } }
        await owner.a.waitUntilHeld()
        await identity.unbind()
        await #expect(throws: MacInstallIdentity.Failure.signedOut) {
            try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        }
        await owner.a.release()
        await ending.value
        try await identity.signedIn(stackUser: "stack_a", session: { "session-a" })
        #expect(await identity.installID() != old)
        #expect(await owner.a.registrations == 2)
    }
}
