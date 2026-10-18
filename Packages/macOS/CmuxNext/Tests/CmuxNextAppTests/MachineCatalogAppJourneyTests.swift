@testable import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

@MainActor @Suite(.serialized, .timeLimit(.minutes(3)),
                  .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui and app host"))
struct MachineCatalogAppJourneyTests {
    @Test func actualAppSubscriptionReceivesEmptyInvalidationFromAdmittedServerWatch() async throws {
        let fixture = try MachineCatalogAppFixture(binary: #require(SameTreeDaemonBinary.url))
        do {
            try await fixture.start()
            try await fixture.grantInventory(true)
            _ = try await fixture.run("watch")
            // Only the admitted server has acpmux. Delivery requires the actual
            // JS subscription, native demand, production bridge and owner watch ACK.
            let notice = try await fixture.run("next")
            #expect(notice == .object([:]))
            _ = try await fixture.run("unwatch")
            try await fixture.grantInventory(false)
        } catch { await fixture.stop(); throw error }
        await fixture.stop()
    }

    @Test func serverDiscoveryAndScopedInventoryUseTheActualAppProvider() async throws {
        let fixture = try MachineCatalogAppFixture(binary: #require(SameTreeDaemonBinary.url))
        do {
            try await fixture.start()
            let local = try #require(fixture.local.identity?.machineResourceID?.rawValue)
            let server = try #require(fixture.server?.daemon.identity?.machineResourceID?.rawValue)
            #expect(local != server)
            let catalog = try #require(try await fixture.run("discover").arrayValue)
            #expect(catalog.count == 2)
            #expect(catalog.first?["id"] == .string(local))
            #expect(catalog.last?["id"] == .string(server))
            #expect(catalog.last?["origin"] == .string("server"))

            await expectRefusal("scope.missing") { try await fixture.run("inventory", params: ["machine": .string(server)]) }
            try await fixture.grantInventory(true)
            let inventory = try await fixture.run("inventory", params: ["machine": .string(server), "check_latest": .bool(false)])
            #expect(inventory["machine"] == .string(server))
            #expect(inventory["cached"] == .bool(true))
            #expect(inventory["complete"] == .bool(false))
            #expect(inventory["clis"] == .array([]))
            // Only the server's acpmux is running: falling back to the Mac cannot pass.
            await expectRefusal("agent_inventory.unavailable") { try await fixture.run("inventory", params: ["machine": .string(local)]) }
            await expectRefusal("operation.unsupported") { try await fixture.run("inventory", params: ["machine": .string(server), "check_latest": .bool(true)]) }
            try await fixture.grantInventory(false)
            await expectRefusal("scope.missing") { try await fixture.run("inventory", params: ["machine": .string(server)]) }

            try await fixture.grantInventory(true)
            let removed = try #require(fixture.server)
            let beforeWithdrawal = fixture.publisher?.publishedSequence
            _ = fixture.registry.removeServer(removed.machineID)
            do {
                try await fixture.wait("registry withdrawal") {
                    guard let publisher = fixture.publisher else { return false }
                    return publisher.publishedOwner?.rawValue == local && publisher.publishedSequence != nil
                        && publisher.current?.machines.isEmpty == true
                }
            } catch {
                let observed = try? await fixture.run("discover")
                let observedIDs = observed?.arrayValue?.compactMap { $0["id"]?.stringValue }
                let projectedIDs = fixture.publisher?.current?.machines.map { $0.id.rawValue }
                print("catalog withdrawal: before=\(String(describing: beforeWithdrawal)), after=\(String(describing: fixture.publisher?.publishedSequence)), projected=\(String(describing: projectedIDs)), observed=\(String(describing: observedIDs))")
                throw error
            }
            let after = try #require(try await fixture.run("discover").arrayValue)
            #expect(after.map { $0["id"] } == [.string(local)])
            await expectRefusal("machine.unavailable") { try await fixture.run("inventory", params: ["machine": .string(server)]) }
        } catch {
            await fixture.stop()
            throw error
        }
        await fixture.stop()
    }

    private func expectRefusal(_ wanted: String, _ operation: () async throws -> JSONValue) async {
        do {
            _ = try await operation()
            Issue.record("expected \(wanted)")
        } catch let DaemonError.command(_, _, code, _, _) {
            #expect(code == wanted)
        } catch { Issue.record("expected \(wanted), received \(error)") }
    }
}
