import Foundation
import Testing
@testable import CmuxWorkspaces

struct RestorePassCheckpointClaimStoreTests {
    @Test func claimsSpanNestedPassesAndExpireAtTheOuterBoundary() {
        var store = RestorePassCheckpointClaimStore()
        let key = RestorePassCheckpointClaimStore.Checkpoint(kind: "codex", sessionID: "a")
        #expect(store.claim(key) == .unscoped)
        store.beginRestorePass()
        #expect(store.claim(key) == .owner)
        store.beginRestorePass()
        #expect(store.claim(key) == .duplicate)
        store.endRestorePass()
        #expect(store.claim(key) == .duplicate)
        store.endRestorePass()
        #expect(store.claim(key) == .unscoped)
        store.beginRestorePass()
        #expect(store.claim(key) == .owner)
        for index in 0..<128 {
            let other = RestorePassCheckpointClaimStore.Checkpoint(kind: "codex", sessionID: "b-\(index)")
            #expect(store.claim(other) == .owner)
        }
    }

    @Test func failedTransfersReleaseOnlyTheirOwnClaims() {
        var store = RestorePassCheckpointClaimStore()
        let key = RestorePassCheckpointClaimStore.Checkpoint(kind: "pi", sessionID: "session")
        let original = UUID()
        let replacement = UUID()
        store.beginRestorePass()
        #expect(store.claim(key) == .owner)
        store.recordOwner(key, panelID: original)
        store.release(panelID: UUID())
        #expect(store.claim(key) == .duplicate)
        store.release(key)
        #expect(store.claim(key) == .owner)
        store.recordOwner(key, panelID: replacement)
        // The first owner's late cleanup cannot remove the replacement.
        store.release(panelID: original)
        #expect(store.claim(key) == .duplicate)
        store.release(panelID: replacement)
        #expect(store.claim(key) == .owner)
        store.reset()
        store.beginRestorePass()
        #expect(store.claim(key) == .owner)
        store.release(panelID: replacement)
        #expect(store.claim(key) == .duplicate)
    }
}
