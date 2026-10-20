import Foundation
import Testing
@testable import CmuxNextCloud

@Suite struct MacInstallAuthorityGenerationTests {
    @Test func recordReplacementKeepsPersistenceCallbacksAndInvalidatesTheOriginalContext() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = MacTeamAuthOwner(), store = MacInstallStore.files(directory: root)
        let identity = MacInstallIdentity(store: store, transport: owner, deviceName: "Test Mac", clientVersion: "2.4.0")
        var changes = await identity.authorityGenerations().makeAsyncIterator()
        #expect(await changes.next() == 0)
        try await identity.signedIn(stackUser: "stack_1", session: { "test-session" })
        let original = try await identity.accountContext()
        let pinned = try await identity.boundAccountContext()
        #expect(pinned.install == original.install && pinned.generation == original.generation)
        #expect(await changes.next() == original.generation)
        await identity.invalidate()
        #expect(await identity.authorityGeneration == original.generation)
        await owner.denyPersonalRecovery()
        _ = try await identity.boundAccountContext()
        #expect(await owner.registrations == 1)
        for expected in ["inst_2", "inst_3"] {
            await #expect(throws: (any Error).self) { try await identity.installToken() }
            #expect(store.record(for: "stack_1")?.install == expected)
            let generation = await identity.authorityGeneration
            #expect(generation > original.generation)
            #expect(await changes.next() == generation)
            await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await identity.nativeCheck(original) }
            await #expect(throws: MacInstallIdentity.Failure.signedOut) { try await identity.boundAccountContext() }
        }
        #expect(await owner.registrations == 3)
        let before = await identity.authorityGeneration
        await identity.unbind()
        #expect(await changes.next() == before + 1)
        #expect(store.record(for: "stack_1")?.install == "inst_3")
    }
}
