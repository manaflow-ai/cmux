import CmuxNextApps
import Testing

struct AppHostCapabilitiesTests {
    @Test func dispatchPreservesTheCallingAppOriginAndMachineParams() async throws {
        let owner = Owner()
        let router = AppHostCapabilities([owner])
        let params: AppJSON = ["machine": "server_a", "check_latest": false]
        let reply = try await router.handle(.init(app: "cmux/agents", op: "agent_cli.list", params: params, origin: "script"))
        #expect(reply == .object(["app": .string("cmux/agents"), "op": .string("agent_cli.list"), "origin": .string("script"), "params": params]))
        #expect(router.families == ["agent_cli"])
        #expect(await owner.calls == 1)
    }

    @Test func anUnownedFamilyNeverReachesAnOwner() async throws {
        let owner = Owner()
        let router = AppHostCapabilities([owner])
        #expect(!router.handles("other.list"))
        do throws(AppHostCapabilityError) {
            _ = try await router.handle(.init(app: "cmux/agents", op: "other.list", params: [:], origin: "user"))
            Issue.record("an unowned family was dispatched")
        } catch {
            #expect(error.code == "operation.unsupported")
            #expect(error.details == .object(["op": .string("other.list")]))
            #expect(!error.retryable)
        }
        #expect(await owner.calls == 0)
    }

    @Test func theOwnerStillRefusesUnsupportedOpsWithinItsFamily() async throws {
        let owner = Owner()
        let router = AppHostCapabilities([owner])
        #expect(router.handles("agent_cli.update"))
        do throws(AppHostCapabilityError) {
            _ = try await router.handle(.init(app: "cmux/agents", op: "agent_cli.update", params: [:], origin: "user"))
            Issue.record("the owner refusal was lost")
        } catch {
            #expect(error.code == "owner.read_only")
            #expect(error.message == "read only")
            #expect(error.details == .object(["op": .string("agent_cli.update")]))
            #expect(error.retryable)
        }
        #expect(await owner.calls == 1)
    }

    private actor Owner: AppHostCapabilityHandler {
        nonisolated let families: Set<String> = ["agent_cli"]
        private(set) var calls = 0

        func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
            calls += 1
            guard request.op == "agent_cli.list" else {
                throw AppHostCapabilityError(code: "owner.read_only", message: "read only", retryable: true, details: ["op": .string(request.op)])
            }
            return ["app": .string(request.app), "op": .string(request.op), "origin": .string(request.origin), "params": request.params]
        }
    }
}
