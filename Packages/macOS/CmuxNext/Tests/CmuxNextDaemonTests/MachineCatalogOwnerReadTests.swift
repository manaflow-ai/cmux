import Foundation
import Testing
@testable import CmuxNextDaemon

/// Real Swift resource requests to an isolated same-tree owner. No app, Cloud account,
/// personal config, terminal, or inventory refresh is needed for metadata discovery.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct MachineCatalogOwnerReadTests {
    @Test func catalogReadsMatchTheConnectedOwnersIdentity() async throws {
        try await withOwner { h in
            let owner = try #require(h.identity.machineResourceID?.rawValue)
            let client = ResourceRelayClient(connection: h.connection)
            let listed = try await client.send(operation: "machine.list", params: [:], idempotencyKey: nil)
            let machines = try #require(listed.arrayValue)
            #expect(machines.count == 1)
            #expect(machines.first?["id"] == .string(owner))
            #expect(machines.first?["origin"] == .string("local"))

            let selected = try await client.send(operation: "machine.get", params: ["machine": .string(owner)], idempotencyKey: nil)
            #expect(selected == machines.first)
            let current = try await client.send(operation: "machine.get", params: [:], idempotencyKey: nil)
            #expect(current == selected)
            let sessions = try await client.send(operation: "session.list", params: ["machine": .string(owner)], idempotencyKey: nil)
            #expect(sessions.arrayValue?.isEmpty == false)
        }
    }

    @Test func unknownOwnerIsRefusedWithoutLocalFallback() async throws {
        try await withOwner { h in
            let owner = try #require(h.identity.machineResourceID?.rawValue)
            let other = "machine_00000000000000000000000000000001" == owner
                ? "machine_00000000000000000000000000000002"
                : "machine_00000000000000000000000000000001"
            do {
                _ = try await ResourceRelayClient(connection: h.connection).send(
                    operation: "machine.get", params: ["machine": .string(other)], idempotencyKey: nil)
                Issue.record("an unknown owner resolved to the local machine")
            } catch let DaemonError.command(_, _, code, _, _) {
                #expect(code == "selector.not_found")
            }
        }
    }

    @Test func explicitUnsupportedSelectorStillGetsNativeRefusal() async throws {
        try await withOwner { h in
            let client = ResourceRelayClient(connection: h.connection)
            do {
                _ = try await client.send(operation: "machine.list", params: ["session": .string("current")], idempotencyKey: nil)
                Issue.record("an unsupported session selector was silently discarded")
            } catch let DaemonError.command(_, _, code, _, _) {
                #expect(code == "validation.invalid")
            }
            let listed = try await client.send(operation: "machine.list", params: [:], idempotencyKey: nil)
            #expect(listed.arrayValue?.count == 1)
        }
    }

    private func withOwner(_ body: (BranchDaemonHarness) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cnd-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["HOME": root.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/sh",
                           "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                           "ACPMUX_HOME": root.appendingPathComponent("acpmux").path]
        try await BranchDaemonHarness.with(daemonEnvironment: environment, body)
    }
}
