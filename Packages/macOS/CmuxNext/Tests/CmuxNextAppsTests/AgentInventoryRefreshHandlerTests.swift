import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing

@MainActor
struct AgentInventoryRefreshHandlerTests {
    private let local: ResourceID = "machine_00000000000000000000000000000001"
    private let remote: ResourceID = "machine_00000000000000000000000000000002"

    @Test func explicitRefreshUsesOnlyTheCapturedRemoteCarrier() async throws {
        let a = AgentInventoryRefreshTestReader(snapshot: try snapshot())
        let b = AgentInventoryRefreshTestReader(snapshot: try snapshot())
        let handler = AgentCLICapabilityHandler { [local, remote] in [
            .init(machineID: local, reader: a, allowed: true, isDefault: true),
            .init(machineID: remote, reader: b, allowed: true, isDefault: false),
        ] }
        let value = try await handler.handle(request(["machine": .string(remote.rawValue), "check_latest": true]))
        #expect(value["machine"] == .string(remote.rawValue))
        #expect(value["cached"] == true)
        #expect(value["complete"] == false)
        #expect(value["clis"]?.arrayValue?.first?["version"] == "2.0.5")
        #expect(value["clis"]?.arrayValue?.first?["latest"]?["version"] == "2.0.9")
        #expect(await b.refreshes == [remote])
        #expect(await b.reads.isEmpty)
        #expect(await a.refreshes.isEmpty)
        #expect(await a.reads.isEmpty)
    }

    @Test func ordinaryReadsNeverBecomeRegistryRefreshes() async throws {
        let reader = AgentInventoryRefreshTestReader(snapshot: try snapshot())
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        _ = try await handler.handle(request([:]))
        _ = try await handler.handle(request(["check_latest": false]))
        #expect(await reader.reads == [local, local])
        #expect(await reader.refreshes.isEmpty)
    }

    @Test func removalRevocationAndReplacementDiscardRefreshedObservations() async throws {
        for change in 0..<3 {
            let routes = Routes()
            let replacement = AgentInventoryRefreshTestReader(snapshot: try snapshot())
            let reader = AgentInventoryRefreshTestReader(snapshot: try snapshot(), onRefresh: { [local] in
                await MainActor.run {
                    switch change {
                    case 0: routes.values = []
                    case 1: routes.values = [.init(machineID: local, reader: replacement, allowed: false, isDefault: true)]
                    default: routes.values = [.init(machineID: local, reader: replacement, allowed: true, isDefault: true)]
                    }
                }
            })
            routes.values = [.init(machineID: local, reader: reader, allowed: true, isDefault: true)]
            let handler = AgentCLICapabilityHandler { routes.values }
            await refusal(handler, params: ["check_latest": true], code: "machine.unavailable")
            #expect(await reader.refreshes == [local])
            #expect(await reader.reads.isEmpty)
            #expect(await replacement.refreshes.isEmpty)
            #expect(await replacement.reads.isEmpty)
        }
    }

    @Test func cancellationDiscardsACompletedRefresh() async throws {
        let reader = AgentInventoryRefreshTestReader(snapshot: try snapshot(), onRefresh: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        let task = Task { await refusal(handler, params: ["check_latest": true], code: "operation.cancelled") }
        await task.value
        #expect(await reader.refreshes == [local])
        #expect(await reader.reads.isEmpty)
    }

    @Test(arguments: ["agent_inventory.owner_mismatch", "agent_inventory.busy", "agent_inventory.unsupported"])
    func ownerRefusalsNeverFallBackOrExposeDiagnostics(code: String) async throws {
        let reader = AgentInventoryRefreshTestReader(snapshot: try snapshot(),
            error: .command(cmd: "agent-inventory-refresh", message: "/private/token", code: code))
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        await refusal(handler, params: ["check_latest": true], code: code)
        #expect(await reader.refreshes == [local])
        #expect(await reader.reads.isEmpty)
    }

    @Test func unadmittedOwnersAreRefusedBeforeRefreshing() async throws {
        let reader = AgentInventoryRefreshTestReader(snapshot: try snapshot())
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: false, isDefault: true),
        ] }
        await refusal(handler, params: ["check_latest": true], code: "machine.unavailable")
        #expect(await reader.refreshes.isEmpty)
        #expect(await reader.reads.isEmpty)
    }

    private func request(_ params: AppJSON) -> AppHostCapabilityRequest {
        .init(app: "cmux/agents", op: "agent_cli.list", params: params, origin: "script")
    }

    private func refusal(_ handler: AgentCLICapabilityHandler, params: AppJSON, code: String) async {
        do throws(AppHostCapabilityError) {
            _ = try await handler.handle(request(params))
            Issue.record("a refused refresh returned observations")
        } catch {
            #expect(error.code == code)
            #expect(!error.message.contains("private"))
            #expect(error.retryable == (code == "agent_inventory.busy"))
        }
    }

    private func snapshot() throws -> AcpmuxHarnessInventory {
        let value: AppJSON = ["view": "inventory", "cached": true, "harnesses": [[
            "id": "private-profile", "family": "claude", "channel": "native", "version": "2.0.5",
            "latest": "2.0.9", "latestCheckedAt": 456, "outdated": true, "auth": "unknown", "checkedAt": 123,
        ]]]
        return try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: JSONEncoder().encode(value))
    }

    @MainActor private final class Routes {
        var values: [AgentInventoryRoute] = []
    }
}
