import Foundation
@testable import CmuxNextServerHelper
import Testing

/// The privileged helper's shared state is checked Sendable (Mutex state, no
/// `@unchecked`): concurrent requests keep the first recorded value, and a
/// deadline kill that comes before the spawn means the child never runs.
/// Run under TSan to check the stores and the child for data races.
struct ServerHelperConcurrencyTests {
    @Test func memoryStoreKeepsTheFirstOfManyConcurrentRecords() async throws {
        let store = MemoryFixPriorStore()
        await withTaskGroup(of: Void.self) { group in
            for value in 0..<64 {
                group.addTask { try? store.record(.systemSleepOffOnAC, prior: value) }
                group.addTask { _ = store.prior(.systemSleepOffOnAC) }
            }
        }
        let kept = try #require(store.prior(.systemSleepOffOnAC))
        #expect((0..<64).contains(kept))
        try store.record(.systemSleepOffOnAC, prior: 99)
        #expect(store.prior(.systemSleepOffOnAC) == kept)
        try store.clear(.systemSleepOffOnAC)
        #expect(store.prior(.systemSleepOffOnAC) == nil)
    }

    @Test func fileStoreReadModifyWritesNeverInterleave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "server-helper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileFixPriorStore(url: root.appending(path: "store").appending(path: "label.json"))
        let fixes = ServerFix.allCases
        await withTaskGroup(of: Void.self) { group in
            for (index, fix) in fixes.enumerated() {
                for attempt in 0..<16 {
                    group.addTask { try? store.record(fix, prior: index * 100 + attempt) }
                }
            }
        }
        // Each fix's records ran under one lock: every fix kept exactly one of
        // its own values, and no write dropped another fix's entry.
        for (index, fix) in fixes.enumerated() {
            let kept = try #require(store.prior(fix))
            #expect(kept / 100 == index)
        }
        try store.clear(fixes[0])
        #expect(store.prior(fixes[0]) == nil)
        #expect(store.prior(fixes[1]) != nil)
    }

    @Test func childRunsAndReportsItsOutput() async throws {
        let result = try await FixChild(URL(filePath: "/bin/echo"), ["helper"]).start()
        #expect(result == FixRunResult(status: 0, output: "helper\n"))
    }

    /// Regression: the deadline could fire before the request's task spawned
    /// the child; the kill then found nothing running and the child ran
    /// afterwards with no deadline.
    @Test func killBeforeStartNeverSpawnsTheChild() async throws {
        let child = FixChild(URL(filePath: "/bin/echo"), ["late"])
        child.kill()
        await #expect(throws: ServerHelperTimedOut()) { try await child.start() }
    }

    @Test func runnerKillsAChildPastItsLimit() async throws {
        let runner = ProcessFixRunner(limit: .milliseconds(200))
        await #expect(throws: ServerHelperTimedOut()) {
            _ = try await runner.run(URL(filePath: "/bin/sleep"), ["30"])
        }
    }

    @Test func gateWithoutARequirementRefusesEveryConnection() {
        let gate = ServerHelperConnectionGate(service: ServerHelperService(), requirement: nil)
        #expect(!gate.acceptsClients)
        let anonymous = NSXPCListener.anonymous()
        let connection = NSXPCConnection(listenerEndpoint: anonymous.endpoint)
        defer { connection.invalidate() }
        #expect(!gate.listener(anonymous, shouldAcceptNewConnection: connection))
    }
}
