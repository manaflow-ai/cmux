import Foundation
import Testing
@testable import CmuxNextDaemon

/// Same-tree native owners and the production install-key handshake, without a GUI or
/// synthetic trust flags. Both owners run on this test host, with separate state and homes.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct MachineCatalogNativeBoundaryTests {
    @Test func unverifiedConnectionCannotPublish() async throws {
        try await withOwner { h in
            let owner = try #require(h.identity.machineResourceID)
            #expect(await h.connection.userOriginAllowed == false)
            do {
                _ = try await h.connection.request(MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 1, machines: []))
                Issue.record("unverified connection published a machine catalog")
            } catch let DaemonError.command(_, _, code, _, _) {
                #expect(code == "machine_catalog.not_trusted")
            }
        }
    }

    @Test func verifiedConnectionPublishesAndWithdrawsAnObservedOwner() async throws {
        try await withOwner(installKey: .generate()) { local in
            try await withOwner { remote in
                let owner = try #require(local.identity.machineResourceID)
                let other = try #require(remote.identity.machineResourceID)
                #expect(owner != other)
                #expect(await local.connection.userOriginAllowed)
                #expect(local.identity.supports("machine-catalog-publish-v1"))
                let relay = ResourceRelayClient(connection: local.connection)
                let before = try await relay.send(operation: "machine.list", params: ["catalog": .bool(true)], idempotencyKey: nil)
                let record = try #require(MachineCatalogRecord(
                    id: other, name: "isolated server", origin: .server, status: .running,
                    platform: remote.identity.machinePlatform, capabilities: remote.identity.machineCapabilities))

                do {
                    _ = try await local.connection.request(MachineCatalogPublishRequest(expectedMachineID: other, sequence: 1, machines: [record]))
                    Issue.record("publication accepted a different owner fence")
                } catch let DaemonError.command(_, _, code, _, _) {
                    #expect(code == "machine_catalog.owner_mismatch")
                }
                _ = try await local.connection.request(MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 1, machines: [record]))
                let listed = try await relay.send(operation: "machine.list", params: ["catalog": .bool(true)], idempotencyKey: nil)
                let machines = try #require(listed.arrayValue)
                #expect(machines.count == 2)
                #expect(machines.first == before.arrayValue?.first)
                let selected = try await relay.send(operation: "machine.get", params: ["machine": .string(other.rawValue), "catalog": .bool(true)], idempotencyKey: nil)
                #expect(selected == machines.last)
                #expect(selected["id"] == .string(other.rawValue))
                #expect(selected["origin"] == .string("server"))
                #expect(selected["capabilities"] == .array(record.capabilities.map(JSONValue.string)))
                if let platform = record.platform {
                    let encoded = try JSONEncoder().encode(platform)
                    #expect(selected["platform"] == (try JSONDecoder().decode(JSONValue.self, from: encoded)))
                }

                // A projected record is metadata, not a new session carrier.
                do {
                    _ = try await relay.send(operation: "session.list", params: ["machine": .string(other.rawValue)], idempotencyKey: nil)
                    Issue.record("catalog projection granted remote session access")
                } catch let DaemonError.command(_, _, code, _, _) {
                    #expect(code == "selector.not_found")
                }
                _ = try await local.connection.request(MachineCatalogPublishRequest(expectedMachineID: owner, sequence: 2, machines: []))
                let withdrawn = try await relay.send(operation: "machine.list", params: ["catalog": .bool(true)], idempotencyKey: nil)
                #expect(withdrawn == before)
            }
        }
    }

    private func withOwner(installKey: FrontendInstallKey? = nil,
                           _ body: (BranchDaemonHarness) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cnd-native-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh",
                           "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "ACPMUX_HOME": root.appendingPathComponent("acpmux").path]
        try await BranchDaemonHarness.with(daemonEnvironment: environment, installKey: installKey, body)
    }
}
