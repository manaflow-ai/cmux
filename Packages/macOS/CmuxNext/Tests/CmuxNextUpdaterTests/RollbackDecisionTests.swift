import Foundation
import Testing
@testable import CmuxNextUpdater

/// Rollback refuses whenever the old build could not read what the daemon
/// stores now (coordinator decision 2026-10-04), and otherwise picks the
/// newest kept build.
@Suite struct RollbackDecisionTests {
    private func kept(_ build: String, schemas: [String: Int]? = ["workspace_registry": 15, "conversation_store": 2], team: String? = "TEAM") -> KeptVersion {
        KeptVersion(build: build, shortVersion: "1.0.0-nightly.\(build)", bundle: URL(fileURLWithPath: "/tmp/\(build).app"),
                    storeSchemas: schemas, teamID: team)
    }

    @Test func picksTheNewestKeptBuildWhenItReadsEveryStore() {
        let result = RollbackDecision.decide(kept: [kept("2"), kept("1")], build: nil,
                                             stored: ["workspace_registry": 15, "conversation_store": 2], teamID: "TEAM")
        #expect(result == .success(kept("2")))
    }

    @Test func picksTheBuildAskedFor() {
        let result = RollbackDecision.decide(kept: [kept("2"), kept("1")], build: "1", stored: ["workspace_registry": 14], teamID: "TEAM")
        #expect(result == .success(kept("1")))
        #expect(RollbackDecision.decide(kept: [kept("2")], build: "9", stored: [:], teamID: "TEAM") == .failure(.nothingKept))
        #expect(RollbackDecision.decide(kept: [], build: nil, stored: [:], teamID: "TEAM") == .failure(.nothingKept))
    }

    @Test func refusesWhenAStoreIsNewerThanTheOldBuildReads() {
        let result = RollbackDecision.decide(kept: [kept("2")], build: nil, stored: ["workspace_registry": 16], teamID: "TEAM")
        #expect(result == .failure(.storeTooNew(store: "workspace_registry", stored: 16, readable: 15, kept: kept("2"))))
    }

    @Test func refusesAStoreTheOldBuildDoesNotKnow() {
        let result = RollbackDecision.decide(kept: [kept("2")], build: nil, stored: ["history": 1], teamID: "TEAM")
        #expect(result == .failure(.unknownStore(store: "history", kept: kept("2"))))
    }

    @Test func refusesABuildFromBeforeRollbackSupport() {
        let old = kept("2", schemas: nil)
        #expect(RollbackDecision.decide(kept: [old], build: nil, stored: [:], teamID: "TEAM") == .failure(.predatesRollback(old)))
    }

    @Test func refusesABundleFromAnotherTeam() {
        let other = kept("2", team: "OTHER")
        #expect(RollbackDecision.decide(kept: [other], build: nil, stored: [:], teamID: "TEAM") == .failure(.signature(other)))
        let unsigned = kept("2", team: nil)
        #expect(RollbackDecision.decide(kept: [unsigned], build: nil, stored: [:], teamID: "TEAM") == .failure(.signature(unsigned)))
    }

    @Test func theMessageNamesTheStoreAndBothVersions() {
        let message = RollbackRefusal.storeTooNew(store: "workspace_registry", stored: 16, readable: 15, kept: kept("2")).message
        #expect(message.contains("1.0.0-nightly.2"))
        #expect(message.contains("16"))
        #expect(message.contains("15"))
    }
}
