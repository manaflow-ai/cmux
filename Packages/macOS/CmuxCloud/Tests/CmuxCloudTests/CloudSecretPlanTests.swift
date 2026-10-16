@testable import CmuxCloud
import Foundation
import Testing

/// Effective-set precedence, sync plans, the delivery ledger and machine status.
@Suite struct CloudSecretPlanTests {
    let storage = InMemoryCloudSecretVaultStorage()

    func makeVault() -> CloudSecretVault {
        CloudSecretVault(storage: storage, now: { Date(timeIntervalSince1970: 1_000) })
    }

    func input(_ name: String, _ value: String) -> CloudSecretInput {
        CloudSecretInput(name: name, value: value)
    }

    @Test
    func mostSpecificScopeWins() async throws {
        let vault = makeVault()
        try await vault.set([input("SHARED", "all"), input("ONLY_ALL", "a")], scope: .all, source: .manual)
        try await vault.set([input("SHARED", "project"), input("ONLY_PROJECT", "p")], scope: .project("github.com/o/r"), source: .manual)
        try await vault.set([input("SHARED", "machine")], scope: .machine("m1"), source: .manual)
        try await vault.set([input("OTHER_MACHINE", "x")], scope: .machine("m2"), source: .manual)
        try await vault.set([input("UNLINKED", "x")], scope: .project("github.com/o/other"), source: .manual)
        try await vault.linkMachine("m1", projectKey: "github.com/o/r")

        let plan = try await vault.plan(machineID: "m1")
        #expect(plan.effective == [
            "SHARED": .machine("m1"),
            "ONLY_ALL": .all,
            "ONLY_PROJECT": .project("github.com/o/r")
        ])
        #expect(plan.toSend == [
            CloudEnvDelivery.Entry(key: "ONLY_ALL", value: "a"),
            CloudEnvDelivery.Entry(key: "ONLY_PROJECT", value: "p"),
            CloudEnvDelivery.Entry(key: "SHARED", value: "machine")
        ])
        #expect(plan.toRemove.isEmpty)
        #expect(!plan.isNoop)

        let unlinked = try await vault.plan(machineID: "m3")
        #expect(unlinked.effective == ["SHARED": .all, "ONLY_ALL": .all])
        #expect(unlinked.toSend.first { $0.key == "SHARED" }?.value == "all")
    }

    @Test
    func projectBeatsAllWithoutMachineScope() async throws {
        let vault = makeVault()
        try await vault.set([input("K", "all")], scope: .all, source: .manual)
        try await vault.set([input("K", "project")], scope: .project("p"), source: .manual)
        try await vault.linkMachine("m1", projectKey: "p")
        let plan = try await vault.plan(machineID: "m1")
        #expect(plan.toSend == [CloudEnvDelivery.Entry(key: "K", value: "project")])
        #expect(plan.effective["K"] == .project("p"))
    }

    @Test
    func earlierProjectLinkWinsBetweenProjects() async throws {
        let vault = makeVault()
        try await vault.set([input("K", "first")], scope: .project("first"), source: .manual)
        try await vault.set([input("K", "second")], scope: .project("second"), source: .manual)
        try await vault.linkMachine("m1", projectKey: "first")
        try await vault.linkMachine("m1", projectKey: "second")
        #expect(try await vault.plan(machineID: "m1").effective["K"] == .project("first"))
        try await vault.unlinkMachine("m1", projectKey: "first")
        #expect(try await vault.plan(machineID: "m1").effective["K"] == .project("second"))
        #expect(try await vault.delivery(for: "m1")?.projectKeys == ["second"])
    }

    @Test
    func linkIsIdempotent() async throws {
        let vault = makeVault()
        try await vault.linkMachine("m1", projectKey: "p")
        try await vault.linkMachine("m1", projectKey: "p")
        #expect(try await vault.delivery(for: "m1") == CloudSecretDelivery(machineID: "m1", projectKeys: ["p"]))
        try await vault.unlinkMachine("m1", projectKey: "missing")
        try await vault.unlinkMachine("m9", projectKey: "p")
        #expect(try await vault.deliveries().map(\.machineID) == ["m1"])
    }

    @Test
    func ledgerTransitionsFromFirstSyncToRemoval() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1"), input("B", "2")], scope: .all, source: .manual)

        // First sync sends everything.
        let first = try await vault.plan(machineID: "m1")
        #expect(first.sendNames == ["A", "B"])
        try await vault.recordDelivered(machineID: "m1", plan: first, at: Date(timeIntervalSince1970: 2_000))
        let afterFirst = try #require(try await vault.delivery(for: "m1"))
        #expect(Set(afterFirst.delivered.keys) == ["A", "B"])
        #expect(afterFirst.deliveredAt == Date(timeIntervalSince1970: 2_000))
        #expect(try await vault.plan(machineID: "m1").isNoop)

        // An unchanged re-set keeps the machine current.
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        #expect(try await vault.plan(machineID: "m1").isNoop)

        // A changed value resends the full effective set (merge semantics).
        try await vault.set([input("A", "1b")], scope: .all, source: .manual)
        let changed = try await vault.plan(machineID: "m1")
        #expect(changed.toSend == [CloudEnvDelivery.Entry(key: "A", value: "1b"), CloudEnvDelivery.Entry(key: "B", value: "2")])
        #expect(changed.toRemove.isEmpty)
        try await vault.recordDelivered(machineID: "m1", plan: changed, at: Date(timeIntervalSince1970: 3_000))
        #expect(try await vault.plan(machineID: "m1").isNoop)

        // A new secret in an applicable scope makes the names differ.
        try await vault.set([input("C", "3")], scope: .machine("m1"), source: .manual)
        #expect(try await vault.plan(machineID: "m1").sendNames == ["A", "B", "C"])
        let added = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: added, at: Date(timeIntervalSince1970: 3_500))

        // Removing a secret removes it from the machine.
        try await vault.remove(names: ["B"], scope: .all)
        let removal = try await vault.plan(machineID: "m1")
        #expect(removal.toRemove == ["B"])
        #expect(removal.sendNames == ["A", "C"])
        try await vault.recordDelivered(machineID: "m1", plan: removal, at: Date(timeIntervalSince1970: 4_000))
        let afterRemoval = try #require(try await vault.delivery(for: "m1"))
        #expect(Set(afterRemoval.delivered.keys) == ["A", "C"])
        #expect(try await vault.plan(machineID: "m1").isNoop)

        // Removing everything leaves nothing to send and only removals.
        try await vault.remove(names: ["A"], scope: .all)
        try await vault.remove(names: ["C"], scope: .machine("m1"))
        let last = try await vault.plan(machineID: "m1")
        #expect(last.toSend.isEmpty)
        #expect(last.toRemove == ["A", "C"])
        #expect(!last.isNoop)
        try await vault.recordDelivered(machineID: "m1", plan: last, at: Date(timeIntervalSince1970: 5_000))
        #expect(try await vault.delivery(for: "m1")?.delivered == [:])
        #expect(try await vault.plan(machineID: "m1").isNoop)
    }

    @Test
    func ledgerRecordsWhatThePlanSentNotWhatChangedSince() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        let plan = try await vault.plan(machineID: "m1")
        try await vault.set([input("A", "2")], scope: .all, source: .manual)
        try await vault.recordDelivered(machineID: "m1", plan: plan, at: Date(timeIntervalSince1970: 2_000))
        #expect(try await vault.plan(machineID: "m1").sendNames == ["A"])
        let rows = try await vault.status(machineID: "m1", namesOnMachine: nil)
        #expect(rows.map(\.state) == [.stale])
    }

    @Test
    func partialDeliveryKeepsHeldBackNamesInTheLedger() async throws {
        let vault = makeVault()
        try await vault.set([input("OPENAI_API_KEY", "old"), input("ANTHROPIC_API_KEY", "same")], scope: .all, source: .manual)
        let first = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: first, at: Date(timeIntervalSince1970: 2_000))

        try await vault.set([input("OPENAI_API_KEY", "rotated")], scope: .all, source: .manual)
        let full = try await vault.plan(machineID: "m1")
        let partial = CloudSecretPlan(
            machineID: full.machineID,
            toSend: full.toSend.filter { $0.key == "ANTHROPIC_API_KEY" },
            toRemove: full.toRemove,
            effective: full.effective,
            fingerprints: full.fingerprints
        )
        try await vault.recordDelivered(machineID: "m1", plan: partial, at: Date(timeIntervalSince1970: 3_000))

        let delivery = try #require(try await vault.delivery(for: "m1"))
        #expect(Set(delivery.delivered.keys) == ["OPENAI_API_KEY", "ANTHROPIC_API_KEY"])
        // A changed fingerprint resends the full effective set because delivery merges
        // entries into the machine's environment. The ledger still retains the held-back
        // name, so a later revoke can remove it reliably.
        #expect(try await vault.plan(machineID: "m1").sendNames == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])

        try await vault.remove(names: ["OPENAI_API_KEY"], scope: .all)
        #expect(try await vault.plan(machineID: "m1").toRemove == ["OPENAI_API_KEY"])
    }

    @Test
    func failureIsRecordedAndClearedBySuccess() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        try await vault.recordFailure(machineID: "m1", message: "machine is asleep")
        #expect(try await vault.delivery(for: "m1")?.lastError == "machine is asleep")
        let currentM1 = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: currentM1, at: Date(timeIntervalSince1970: 2_000))
        #expect(try await vault.delivery(for: "m1")?.lastError == nil)
    }

    @Test
    func recordDeliveredRefusesAnotherMachinesPlan() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        let plan = try await vault.plan(machineID: "m1")
        await #expect(throws: CloudSecretVaultError.planMachineMismatch(expected: "m2", actual: "m1")) {
            try await vault.recordDelivered(machineID: "m2", plan: plan, at: Date())
        }
        #expect(try await vault.delivery(for: "m2") == nil)
    }

    @Test
    func machinesNeedingSyncListsStaleLedgerEntries() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        try await vault.linkMachine("m1", projectKey: "p")
        try await vault.linkMachine("m2", projectKey: "p")
        let currentM2 = try await vault.plan(machineID: "m2")
        try await vault.recordDelivered(machineID: "m2", plan: currentM2, at: Date())
        #expect(try await vault.machinesNeedingSync() == ["m1"])
        try await vault.set([input("A", "2")], scope: .all, source: .manual)
        #expect(try await vault.machinesNeedingSync() == ["m1", "m2"])
    }

    @Test
    func forgetMachineDropsLedgerAndMachineScope() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        try await vault.set([input("B", "1")], scope: .machine("m1"), source: .manual)
        try await vault.set([input("C", "1")], scope: .machine("m2"), source: .manual)
        try await vault.linkMachine("m1", projectKey: "p")
        try await vault.forgetMachine("m1")
        #expect(try await vault.delivery(for: "m1") == nil)
        #expect(try await vault.records().map(\.name) == ["A", "C"])
    }

    @Test
    func aSyncThatFinishesAfterForgetMachineDoesNotResurrectIt() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        // A plan made before the machine was destroyed, recorded after.
        let inFlight = try await vault.plan(machineID: "m1")
        try await vault.forgetMachine("m1")
        try await vault.recordDelivered(machineID: "m1", plan: inFlight, at: Date())
        try await vault.recordFailure(machineID: "m1", message: "late")
        #expect(try await vault.delivery(for: "m1") == nil)
        #expect(try await vault.deliveries().isEmpty)
    }

    @Test
    func ledgerPersistsAcrossVaultInstances() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        try await vault.linkMachine("m1", projectKey: "p")
        let currentM1 = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: currentM1, at: Date(timeIntervalSince1970: 2_000))
        let reloaded = CloudSecretVault(storage: storage)
        let original = try await vault.deliveries()
        #expect(try await reloaded.deliveries() == original)
        #expect(try await reloaded.plan(machineID: "m1").isNoop)
    }

    // MARK: Status

    @Test
    func statusReportsCurrentStaleMissingAndExtra() async throws {
        let vault = makeVault()
        try await vault.set([input("CURRENT", "1"), input("STALE", "1"), input("GONE", "1")], scope: .all, source: .manual)
        let currentM1 = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: currentM1, at: Date())
        try await vault.set([input("STALE", "2"), input("NEW", "1")], scope: .all, source: .manual)
        try await vault.remove(names: ["GONE"], scope: .all)

        let rows = try await vault.status(machineID: "m1", namesOnMachine: nil)
        #expect(rows.map(\.name) == ["CURRENT", "GONE", "NEW", "STALE"])
        #expect(rows.map(\.state) == [.current, .extra, .missing, .stale])
        let gone = try #require(rows.first { $0.name == "GONE" })
        #expect(gone.scope == nil)
        #expect(gone.fingerprint != nil)
        let current = try #require(rows.first { $0.name == "CURRENT" })
        #expect(current.scope == .all)
    }

    @Test
    func verifiedNamesOverrideTheLedger() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1"), input("B", "1")], scope: .all, source: .manual)
        try await vault.set([input("ELSEWHERE", "1")], scope: .machine("m2"), source: .manual)
        let currentM1 = try await vault.plan(machineID: "m1")
        try await vault.recordDelivered(machineID: "m1", plan: currentM1, at: Date())

        let rows = try await vault.status(machineID: "m1", namesOnMachine: ["A", "ELSEWHERE", "USER_OWN"])
        let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.state) })
        #expect(states == ["A": .current, "B": .missing, "ELSEWHERE": .extra])
    }

    @Test
    func statusForUnknownMachineIsAllMissing() async throws {
        let vault = makeVault()
        try await vault.set([input("A", "1")], scope: .all, source: .manual)
        let rows = try await vault.status(machineID: "new", namesOnMachine: nil)
        let fingerprint = try await vault.records().first?.fingerprint
        #expect(rows == [CloudSecretMachineStatusRow(name: "A", scope: .all, state: .missing, fingerprint: fingerprint)])
    }
}
