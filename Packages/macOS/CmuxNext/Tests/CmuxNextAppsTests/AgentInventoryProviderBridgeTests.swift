import Foundation
import Testing
@testable import CmuxNextApps
@testable import CmuxNextDaemon

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentInventoryProviderBridgeTests {
    @Test func firstAndLastDemandUseExactGenerationAndIgnoreForeignNotices() async throws {
        let f = InventoryProviderBridgeFixture()
        do {
            try await f.start()
            #expect(try await f.state().map { $0["kind"] } == [.string("register")])
            f.demand(9_007_199_254_740_993, true)
            try await f.wait("invalidate")
            f.demand(9_007_199_254_740_994, false, source: UUID())
            f.demand(9_007_199_254_740_994, false, serial: f.session.serial + 1)
            f.changed(revision: 2, source: UUID())
            f.changed(revision: 2, serial: f.session.serial + 1)
            f.changed(revision: 2, watch: "inventory_watch_ffffffffffffffffffffffffffffffff")
            f.changed(revision: 2)
            try await f.wait("invalidate", 2)
            f.demand(9_007_199_254_740_994, false)
            try await f.wait("disable")
            f.demand(9_007_199_254_740_993, true)
            f.changed(revision: 3)
            let calls = try await f.state()
            #expect(calls.filter { $0["kind"] == .string("enable") }.count == 1)
            let changes = calls.filter { $0["kind"] == .string("invalidate") }
            #expect(changes.count == 2)
            #expect(changes.allSatisfy { $0["sequence"] == .string("9007199254740993") && $0["strict"] == .bool(true) })
            #expect(calls.last?["expected_watch_id"] == .string("inventory_watch_0123456789abcdef0123456789abcdef"))
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func newerDemandEventWinsOverRegistrationSnapshot() async throws {
        let f = InventoryProviderBridgeFixture(mode: "early")
        do {
            try await f.start()
            try await f.wait("invalidate")
            let calls = try await f.state()
            #expect(calls.first?["opted_in"] == .bool(true))
            #expect(calls.last?["sequence"] == .string("9007199254740993"))
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func revocationDuringPendingEnableRetiresRecoveredReceiptWithoutInvalidation() async throws {
        let f = InventoryProviderBridgeFixture(mode: "hold")
        do {
            try await f.start()
            f.demand(2, true)
            try await f.wait("enable")
            f.routes = []
            f.bridge.reconcile()
            try await f.wait("release", 0)
            try await f.wait("disable")
            let calls = try await f.state()
            #expect(calls.map { $0["kind"] } == [.string("register"), .string("enable"), .string("disable")])
            #expect(calls.last?["expected_watch_id"] == .string("inventory_watch_0123456789abcdef0123456789abcdef"))
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func routeRevocationAndPolicyInvalidateCallbacksBeforeAsyncCleanup() async throws {
        let f = InventoryProviderBridgeFixture()
        do {
            try await f.start()
            f.demand(2, true)
            try await f.wait("invalidate")
            f.routes = []
            // No observation task has run; the callback must read current registry admission.
            f.changed(revision: 2)
            f.bridge.reconcile()
            try await f.wait("disable")
            #expect(try await f.state().filter { $0["kind"] == .string("invalidate") }.count == 1)
            f.routes = [.init(machine: f.machine, connection: f.connection, epoch: 2, events: f.events)]
            f.bridge.reconcile()
            try await f.wait("invalidate", 2)
            f.bridge.setDisabled(true)
            f.changed(revision: 3)
            try await f.wait("disable", 2)
            #expect(try await f.state().filter { $0["kind"] == .string("invalidate") }.count == 2)
            await f.finish()
        } catch { await f.finish(); throw error }
    }
}
