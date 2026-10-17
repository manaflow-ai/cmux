import CmuxNextApps
import CmuxNextDaemon
import Foundation
import Testing

@MainActor
struct AgentCLICapabilityHandlerTests {
    private let local: ResourceID = "machine_00000000000000000000000000000001"
    private let remote: ResourceID = "machine_00000000000000000000000000000002"

    @Test func explicitSelectionAndTheDefaultNeverFallBackToAnotherMachine() async throws {
        let a = AgentInventoryTestReader(snapshot: try snapshot([row(family: "claude")]))
        let b = AgentInventoryTestReader(snapshot: try snapshot([row(family: "codex")]))
        let handler = AgentCLICapabilityHandler { [local, remote] in [
            .init(machineID: remote, reader: b, allowed: true, isDefault: false),
            .init(machineID: local, reader: a, allowed: true, isDefault: true),
        ] }
        let routed = try await handler.handle(request(["machine": .string(remote.rawValue)]))
        #expect(routed["machine"] == .string(remote.rawValue))
        #expect(routed["clis"]?.arrayValue?.first?["cli"] == "codex")
        #expect(await a.requests.isEmpty)
        #expect(await b.requests == [remote])
        let implicit = try await handler.handle(request([:]))
        #expect(implicit["machine"] == .string(local.rawValue))
        #expect(await a.requests == [local])
        #expect(await b.requests == [remote])
    }

    @Test func unknownAmbiguousDisabledDisconnectedAndUnidentifiedRoutesNeverRead() async throws {
        let reader = AgentInventoryTestReader(snapshot: try snapshot([]))
        let box = Routes()
        let handler = AgentCLICapabilityHandler { box.values }
        let admitted = AgentInventoryRoute(machineID: local, reader: reader, allowed: true, isDefault: true)
        box.values = [admitted]
        for alias in [remote.rawValue, "local", "example-host", "SESSION-REGISTRY"] {
            await refusal(handler, params: ["machine": .string(alias)], code: "machine.unavailable")
        }
        box.values = [admitted, admitted]
        await refusal(handler, params: ["machine": .string(local.rawValue)], code: "machine.ambiguous")
        box.values = [.init(machineID: local, reader: reader, allowed: false, isDefault: true)]
        await refusal(handler, params: [:], code: "machine.unavailable")
        box.values = [.init(machineID: local, reader: nil, allowed: true, isDefault: true)]
        await refusal(handler, params: [:], code: "machine.unavailable")
        box.values = [.init(machineID: nil, reader: reader, allowed: true, isDefault: true)]
        await refusal(handler, params: [:], code: "machine.unavailable")
        #expect(await reader.requests.isEmpty)
    }

    @Test func controlsRefreshAndUnsupportedOperationsNeverReachACarrier() async throws {
        let reader = AgentInventoryTestReader(snapshot: try snapshot([]))
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        for params in [AppJSON.null, ["machine": .null], ["machine": true],
                       ["machine": ""], ["command": "private"], ["check_latest": "true"]] {
            await refusal(handler, params: params, code: "validation.invalid")
        }
        await refusal(handler, params: ["check_latest": true], code: "operation.unsupported")
        for op in ["agent_cli.install", "agent_cli.update", "agent_cli.sign_in", "agent_cli.watch", "other.list"] {
            await refusal(handler, params: [:], code: "operation.unsupported", op: op)
        }
        #expect(await reader.requests.isEmpty)
    }

    @Test func removalRevocationAndReplacementDiscardTheInFlightResult() async throws {
        for change in 0..<3 {
            let box = Routes()
            let replacement = AgentInventoryTestReader(snapshot: try snapshot([]))
            let reader = AgentInventoryTestReader(snapshot: try snapshot([row(family: "claude")]), onRead: { [local] in
                await MainActor.run {
                    switch change {
                    case 0: box.values = []
                    case 1: box.values = [.init(machineID: local, reader: replacement, allowed: false, isDefault: true)]
                    default: box.values = [.init(machineID: local, reader: replacement, allowed: true, isDefault: true)]
                    }
                }
            })
            box.values = [.init(machineID: local, reader: reader, allowed: true, isDefault: true)]
            let handler = AgentCLICapabilityHandler { box.values }
            await refusal(handler, params: [:], code: "machine.unavailable")
            #expect(await reader.requests == [local])
            #expect(await replacement.requests.isEmpty)
            box.values = []
        }
    }

    @Test func duplicateObservationsStayPartialWithoutInventedVersionsAccountsOrJobs() async throws {
        let rows = [row(family: "codex", version: "1.2.3", latest: "1.3.0", auth: "signedIn"),
                    row(family: "codex", version: .null, latest: "1.4.0", auth: "signedOut", channel: "brew"),
                    row(family: "claude", version: "2.0.0", latest: "2.0.0", auth: "signedIn"),
                    row(family: "claude", channel: "launcher"), row(family: "private_future_family"),
                    row(family: .null)]
        let reader = AgentInventoryTestReader(snapshot: try snapshot(rows))
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        let value = try await handler.handle(request(["check_latest": false]))
        #expect(value["complete"] == false)
        #expect(value["cached"] == true)
        let clis = try #require(value["clis"]?.arrayValue)
        #expect(clis.count == 2)
        let codex = try #require(clis.first { $0["cli"] == "codex" })
        #expect(codex["installed"] == true)
        #expect(codex["version"] == .null)
        #expect(codex["latest"] == .null)
        #expect(codex["install_method"] == .null)
        #expect(codex["auth_status"] == "unknown")
        #expect(codex["accounts"] == .array([]))
        #expect(codex["updatable"] == false)
        let claude = try #require(clis.first { $0["cli"] == "claude" })
        #expect(claude["version"] == "2.0.0")
        #expect(claude["auth_status"] == "signed_in")
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(!text.contains("private"))
        #expect(!text.contains("profile"))
    }

    @Test func anEmptyCacheNeverEstablishesMissingCLIs() async throws {
        let reader = AgentInventoryTestReader(snapshot: try snapshot([]))
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        let value = try await handler.handle(request([:]))
        #expect(value["clis"] == .array([]))
        #expect(value["complete"] == false)
    }

    @Test func ownerFailuresPreserveSafeCodesWithoutPrivateDiagnosticsOrFallback() async throws {
        for (error, code) in [
            (DaemonError.command(cmd: "agent-inventory", message: "/private/token", code: "agent_inventory.owner_mismatch"), "agent_inventory.owner_mismatch"),
            (.command(cmd: "agent-inventory", message: "/private/token", code: "private_code"), "machine.unavailable"),
            (.missingCapabilities(["agent-inventory-owner-v1"]), "operation.unsupported"),
        ] {
            let reader = AgentInventoryTestReader(snapshot: try snapshot([]), error: error)
            let handler = AgentCLICapabilityHandler { [local] in [
                .init(machineID: local, reader: reader, allowed: true, isDefault: true),
            ] }
            await refusal(handler, params: [:], code: code)
            #expect(await reader.requests == [local])
        }
    }

    @Test func cancelledReadsProduceNoInventoryResult() async throws {
        let reader = AgentInventoryTestReader(snapshot: try snapshot([]), onRead: {
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let handler = AgentCLICapabilityHandler { [local] in [
            .init(machineID: local, reader: reader, allowed: true, isDefault: true),
        ] }
        let task = Task { await refusal(handler, params: [:], code: "operation.cancelled") }
        await task.value
        #expect(await reader.requests == [local])
    }

    private func request(_ params: AppJSON, op: String = "agent_cli.list") -> AppHostCapabilityRequest {
        .init(app: "cmux/agents", op: op, params: params, origin: "script")
    }

    private func refusal(_ handler: AgentCLICapabilityHandler, params: AppJSON, code: String, op: String = "agent_cli.list") async {
        do throws(AppHostCapabilityError) {
            _ = try await handler.handle(request(params, op: op))
            Issue.record("a refused inventory request returned a result")
        } catch {
            #expect(error.code == code)
            #expect(!error.message.contains("private"))
        }
    }

    private func row(family: AppJSON, version: AppJSON = "1.2.3", latest: AppJSON = .null,
                     auth: String = "unknown", channel: String = "npm") -> AppJSON {
        ["id": "private-profile", "family": family, "channel": .string(channel), "version": version,
         "latest": latest, "latestCheckedAt": 456, "outdated": false, "auth": .string(auth), "checkedAt": 123]
    }

    private func snapshot(_ rows: [AppJSON]) throws -> AcpmuxHarnessInventory {
        let value: AppJSON = ["view": "inventory", "cached": true, "harnesses": .array(rows)]
        return try JSONDecoder().decode(AcpmuxHarnessInventory.self, from: JSONEncoder().encode(value))
    }

    @MainActor private final class Routes {
        var values: [AgentInventoryRoute] = []
    }
}
