@testable import CmuxNextControl
import CmuxNextSettings
import Foundation
import Testing

@Suite struct CloudTurnCommandsTests {
    actor Calls {
        var rewinds = 0
        var connected: String?
        func rewind() { rewinds += 1 }
        func connect(_ machine: String, generation: Int) { connected = "\(machine):\(generation)" }
    }

    private func router(_ calls: Calls, connectionGeneration: Int = 1, provider: String = "freestyle", connectionMachine: String = "vm_abcdefghijklmnopqrst") -> ControlRouter {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor())
        router.register(CloudTurnCommands(
            state: { _ in Data(#"{"machineId":"logical","generation":0,"captures":[]}"#.utf8) },
            connection: { _ in
                Data("{\"machineId\":\"logical\",\"generation\":\(connectionGeneration),\"provider\":\"\(provider)\",\"connectionMachine\":\"\(connectionMachine)\"}".utf8)
            },
            rewind: { _ in
                await calls.rewind()
                return Data(#"{"machine":{"id":"logical"},"generation":1}"#.utf8)
            },
            scope: { _ in
                CloudTurnCommands.Scope(machine: "logical") {
                    await calls.connect($0, generation: $1)
                }
            }
        ).methods)
        return router
    }

    private func request(machine: String = "logical") -> ControlRequest {
        ControlRequest(method: "cloud.turn.rewind", params: [
            "workspace": "workspace", "session": "session", "turn": "turn",
            "expectedMachine": .string(machine), "expectedGeneration": 0, "clientKey": "retry-key",
        ])
    }

    @Test func mismatchedNativeScopeNeverRewinds() async {
        let calls = Calls()
        let result = await router(calls).handle(request(machine: "other"))
        guard case .failure(let error) = result else { Issue.record("scope mismatch accepted"); return }
        #expect(error.code == "cloud.turn.scope")
        #expect(await calls.rewinds == 0)
        #expect(await calls.connected == nil)
    }

    @Test func staleConnectionNeverRetargetsTheApp() async {
        let calls = Calls()
        let result = await router(calls, connectionGeneration: 0).handle(request())
        guard case .failure(let error) = result else { Issue.record("stale connection accepted"); return }
        #expect(error.code == "cloud.turn.connection")
        #expect(await calls.rewinds == 1)
        #expect(await calls.connected == nil)
    }

    @Test(arguments: ["freestyle", "freestyle-vm-api", "freestyle-cloud"])
    func successRequiresVerifiedReplacementConnection(provider: String) async throws {
        let calls = Calls()
        let value = try await router(calls, provider: provider).handle(request()).get()
        #expect(value["generation"] == 1)
        #expect(await calls.rewinds == 1)
        #expect(await calls.connected == "vm_abcdefghijklmnopqrst:1")
    }

    @Test func rawProviderHandleAndUnknownProviderCannotRetargetTheApp() async {
        for (provider, target) in [("freestyle-vm-api", "vm_abcdefghijklmnopqrstuvwxyz"), ("unknown", "vm_abcdefghijklmnopqrst"), ("freestyle", "vm_abcdefghijklmnopqrst\\n")] {
            let calls = Calls()
            let result = await router(calls, provider: provider, connectionMachine: target).handle(request())
            guard case .failure(let error) = result else { Issue.record("unverified carrier accepted"); continue }
            #expect(error.code == "cloud.turn.connection")
            #expect(await calls.connected == nil)
        }
    }

}
