import Foundation
import Testing
@testable import CmuxNextApps
@testable import CmuxNextDaemon

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AgentInventoryProviderBridgeTests {
    @Test func laterDemandCanReadmitAfterNegotiatedNoLeaseRefusal() async throws {
        let f = InventoryProviderBridgeFixture(mode: "retry-first")
        do {
            try await f.start()
            f.demand(2, true)
            let firstAdmissions = f.bridge.slots.compactMap(\.admission)
            for admission in firstAdmissions { await admission.value }
            #expect(try await f.state().filter { $0["kind"] == .string("enable") }.count == 1)
            f.demand(3, false)
            f.demand(4, true)
            try await f.wait("invalidate")
            let calls = try await f.state()
            #expect(calls.filter { $0["kind"] == .string("enable") }.count == 2)
            #expect(calls.filter { $0["kind"] == .string("disable") }.isEmpty)
            #expect(calls.last?["sequence"] == .string("4"))
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func staleRegistryRouteCannotAdmitNewlyReconnectedTransport() async throws {
        let f = InventoryProviderBridgeFixture()
        do {
            try await f.start()
            let oldRoutes = f.routes
            f.applyControlStamp = false
            try await f.reconnect()
            let fresh = try await AppProviderSession(connection: f.connection)
            do {
                _ = try await AppProviderSession(connection: f.connection, expectedStamp: try #require(oldRoutes.first?.controlStamp))
                Issue.record("stale observed control admitted a new provider transport")
            } catch DaemonError.notConnected { }
            f.bridge.begin(fresh)
            let snapshot = try await fresh.register(families: ["agent_cli", "action"])
            f.bridge.registered(fresh, snapshot: snapshot)
            f.session = fresh
            // Registry still presents the route admitted before the actor reconnected.
            f.routes = oldRoutes
            f.demand(2, true)
            let admissions = f.bridge.slots.compactMap(\.admission)
            for admission in admissions { await admission.value }
            #expect(try await f.state().filter { $0["kind"] == .string("enable") }.isEmpty)
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test(arguments: ["legacy", "provider"])
    func oldOwnersKeepCompatibleRegistrationWithoutWatches(mode: String) async throws {
        let f = InventoryProviderBridgeFixture(mode: mode)
        do {
            try await f.start()
            f.demand(2, true)
            let calls = try await f.state()
            #expect(calls.count == 1)
            #expect(calls.first?["opted_in"] == .bool(false))
            #expect(calls.first?["families"] == .array((mode == "legacy" ? ["action"] : ["agent_cli", "action"]).map(JSONValue.string)))
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func sameConnectionReconnectCannotRedirectOldProviderOrWatchCallbacks() async throws {
        let f = InventoryProviderBridgeFixture()
        do {
            try await f.start()
            f.demand(2, true)
            try await f.wait("invalidate")
            let old = try #require(f.session)
            try await f.reconnect()
            f.routes = [.init(machine: f.machine, connection: f.connection, epoch: 2, events: f.events)]
            let fresh = try await AppProviderSession(connection: f.connection)
            #expect(fresh.serial != old.serial)
            f.bridge.begin(fresh)
            let snapshot = try await fresh.register(families: ["agent_cli", "action"])
            f.bridge.registered(fresh, snapshot: snapshot)
            f.session = fresh
            f.demand(2, true)
            try await f.wait("invalidate")
            do { try await old.invalidate(sequence: 2); Issue.record("old provider rebound to a new transport") }
            catch { #expect((error as? DaemonError)?.isLostConnection == true) }
            do { try await old.answer(requestID: 1, ok: true, body: .object([:])); Issue.record("old answer rebound to a new transport") }
            catch { #expect((error as? DaemonError)?.isLostConnection == true) }
            f.changed(revision: 2, serial: old.serial)
            f.changed(revision: 2)
            try await f.wait("invalidate", 2)
            let calls = try await f.state()
            #expect(calls.filter { $0["kind"] == .string("enable") }.count == 1)
            #expect(calls.filter { $0["kind"] == .string("invalidate") }.count == 2)
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func endedBeforeAdmissionReplyRetiresWithoutPublishingOrAutomaticallyReadmitting() async throws {
        let f = InventoryProviderBridgeFixture(mode: "hold")
        do {
            try await f.start()
            f.demand(2, true)
            try await f.wait("enable")
            f.ended()
            try await f.wait("release", 0)
            try await f.wait("disable")
            f.bridge.reconcile()
            let calls = try await f.state()
            #expect(calls.map { $0["kind"] } == [.string("register"), .string("enable"), .string("disable")])
            await f.finish()
        } catch { await f.finish(); throw error }
    }

    @Test func delayedOldRegistrationCannotAdmitOrResetItsReplacement() async throws {
        let f = InventoryProviderBridgeFixture()
        do {
            try await f.start()
            let old = try #require(f.session)
            let replacement = try await AppProviderSession(connection: f.connection)
            f.bridge.begin(replacement)
            f.bridge.registered(old, snapshot: .init(sequence: UInt64.max, enabled: true))
            let snapshot = try await replacement.register(families: ["agent_cli", "action"])
            f.bridge.registered(replacement, snapshot: snapshot)
            f.session = replacement
            f.demand(2, true)
            try await f.wait("invalidate")
            f.bridge.rejected(old)
            f.changed(revision: 2)
            try await f.wait("invalidate", 2)
            #expect(try await f.state().filter { $0["kind"] == .string("enable") }.count == 1)
            await f.finish()
        } catch { await f.finish(); throw error }
    }

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
