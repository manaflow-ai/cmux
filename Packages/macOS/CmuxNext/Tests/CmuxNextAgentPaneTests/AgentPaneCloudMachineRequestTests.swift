import Foundation
import Testing
@testable import CmuxNextAgentPane

/// Leo, 2026-10-26: "the dropdown should show the states of stuff when you've done the acp things
/// or any kind of connectivity." The environment picker reads the account's Cloud machines
/// (`cloudMachine.list`), so a paused one shows with its state, and Open or Resume runs on a click.
@MainActor
struct AgentPaneCloudMachineRequestTests {
    private static func request(_ method: String, _ params: [String: Any]? = nil) -> AgentPaneRequest {
        AgentPaneRequest(body: params.map { ["method": method, "params": $0] } ?? ["method": method])
    }

    @Test func decodesTheMachineMethods() {
        #expect(Self.request("cloudMachine.list", [:]) == .cloudMachine(.list))
        #expect(Self.request("cloudMachine.list") == .cloudMachine(.list))
        #expect(Self.request("cloudMachine.recoveryList") == .cloudMachine(.recoveryList))
        #expect(Self.request("cloudMachine.open", ["id": "vm-abc123"]) == .cloudMachine(.open(id: "vm-abc123")))
        #expect(Self.request("cloudMachine.resume", ["id": "machine_0123"]) == .cloudMachine(.resume(id: "machine_0123")))
        #expect(Self.request("cloudMachine.attach", ["id": "vm-1"]) == .cloudMachine(.attach(id: "vm-1")))
        #expect(Self.request("cloudMachine.pause", ["id": "vm_0123"]) == .cloudMachine(.pause(id: "vm_0123")))
        #expect(Self.request("cloudMachine.prewarm", ["id": "vm_0123"]) == .cloudMachine(.prewarm(id: "vm_0123")))
        for method in AgentPaneCloudMachineRequest.methods { #expect(AgentPageOps.methods[method] == method) }
        #expect(String(describing: Self.request("cloudMachine.open", ["id": "vm-1"])) == "cloudMachine")
    }

    @Test func refusesAnIDOutsideTheContract() {
        let refused: [[String: Any]] = [
            ["id": ""], ["id": "vm 1"], ["id": "vm-1\n"], ["id": "vm/1"], ["id": "vm-é"], ["id": 7],
            ["id": String(repeating: "a", count: 129)], ["id": "vm-1", "extra": true], [:],
        ]
        for params in refused {
            #expect(Self.request("cloudMachine.open", params) == .unsupported("cloudMachine.open"))
            #expect(Self.request("cloudMachine.resume", params) == .unsupported("cloudMachine.resume"))
            #expect(Self.request("cloudMachine.attach", params) == .unsupported("cloudMachine.attach"))
            #expect(Self.request("cloudMachine.pause", params) == .unsupported("cloudMachine.pause"))
            #expect(Self.request("cloudMachine.prewarm", params) == .unsupported("cloudMachine.prewarm"))
        }
    }

    @Test func aListWithParamsIsRefused() {
        #expect(Self.request("cloudMachine.list", ["account": "other"]) == .unsupported("cloudMachine.list"))
    }

    @Test func theListAnswersTheAppsRowsAndIsPassive() async throws {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        // Unset (no App): refused.
        #expect(await AgentPaneCloudMachineRequest.list.reply(machines, gestures: gestures)["ok"] as? Bool != true)
        machines.list = {
            .init(signedIn: true, loaded: true, machines: [
                .init(id: "vm-1", name: "build box", stage: "paused"),
                .init(id: "vm-2", name: "gpu", stage: "ready"),
            ])
        }
        let reply = await AgentPaneCloudMachineRequest.list.reply(machines, gestures: gestures)
        let value = try #require(reply["value"] as? [String: Any])
        #expect(value["signedIn"] as? Bool == true && value["loaded"] as? Bool == true)
        let rows = try #require(value["machines"] as? [[String: String]])
        #expect(rows == [["id": "vm-1", "name": "build box", "stage": "paused"], ["id": "vm-2", "name": "gpu", "stage": "ready"]])
        #expect(JSONSerialization.isValidJSONObject(reply))
        // Reading the list is not the person touching the page.
        let model = AgentPaneModel(host: NoHost())
        _ = await model.respond(to: .cloudMachine(.list))
        #expect(!model.userTouched)
        _ = await model.respond(to: .cloudMachine(.recoveryList))
        #expect(!model.userTouched)
        machines.prewarm = { _ in true }
        model.cloudMachines = machines
        _ = await model.respond(to: .cloudMachine(.prewarm(id: "vm-1")))
        #expect(!model.userTouched)
    }

    @Test func aSignedOutAccountListsNothing() async throws {
        let machines = AgentPaneCloudMachines()
        machines.list = { .init(signedIn: false, loaded: false, machines: []) }
        let value = try #require(await AgentPaneCloudMachineRequest.list.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(value["signedIn"] as? Bool == false && value["loaded"] as? Bool == false)
        #expect((value["machines"] as? [Any])?.isEmpty == true)
    }

    @Test func openResumeAndPauseTakeOneGestureEach() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        var ran: [String] = []
        machines.open = { ran.append("open " + $0); return true }
        machines.resume = { ran.append("resume " + $0); return true }
        machines.pause = { ran.append("pause " + $0); return true }
        // No click: nothing runs.
        #expect(await AgentPaneCloudMachineRequest.resume(id: "vm-1").reply(machines, gestures: gestures)["ok"] as? Bool != true)
        #expect(ran.isEmpty)
        gestures.record(click: true)
        #expect(await AgentPaneCloudMachineRequest.resume(id: "vm-1").reply(machines, gestures: gestures)["ok"] as? Bool == true)
        // The click is spent.
        #expect(await AgentPaneCloudMachineRequest.open(id: "vm-2").reply(machines, gestures: gestures)["ok"] as? Bool != true)
        gestures.record(click: true)
        #expect(await AgentPaneCloudMachineRequest.open(id: "vm-2").reply(machines, gestures: gestures)["ok"] as? Bool == true)
        // Pause changes the machine too: no click, nothing runs; a click runs it once.
        #expect(await AgentPaneCloudMachineRequest.pause(id: "vm-3").reply(machines, gestures: gestures)["ok"] as? Bool != true)
        gestures.record(click: true)
        #expect(await AgentPaneCloudMachineRequest.pause(id: "vm-3").reply(machines, gestures: gestures)["ok"] as? Bool == true)
        #expect(ran == ["resume vm-1", "open vm-2", "pause vm-3"])
    }

    @Test func aMachineTheAppRefusesIsAVisibleFailure() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        machines.resume = { _ in false }
        gestures.record(click: true)
        let reply = await AgentPaneCloudMachineRequest.resume(id: "vm-running").reply(machines, gestures: gestures)
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
    }

    @Test func typingPrewarmIsPassiveAndDoesNotConsumeAGesture() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        var hinted: [String] = []
        machines.prewarm = { id in hinted.append(id); return true }
        gestures.record(click: true)
        let reply = await AgentPaneCloudMachineRequest.prewarm(id: "vm-paused").reply(machines, gestures: gestures)
        #expect(reply["ok"] as? Bool == true)
        #expect(hinted == ["vm-paused"])
        #expect(gestures.isAvailable)
    }

    @Test func withoutTheAppTheGestureIsKept() async {
        let gestures = AgentPaneUserGestures()
        gestures.record(click: true)
        #expect(await AgentPaneCloudMachineRequest.open(id: "vm-1").reply(AgentPaneCloudMachines(), gestures: gestures)["ok"] as? Bool != true)
        #expect(gestures.isAvailable)
    }

    @Test func recoveryAttachConsumesOneGestureAndDoesNotOpenAWorkspace() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        var attached: [String] = []
        machines.attach = { attached.append($0); return true }
        machines.open = { _ in Issue.record("Recovery must not open a workspace"); return false }
        let request = AgentPaneCloudMachineRequest.attach(id: "vm-1")
        #expect(await request.reply(machines, gestures: gestures)["ok"] as? Bool != true)
        gestures.record(click: true)
        #expect(await request.reply(machines, gestures: gestures)["ok"] as? Bool == true)
        #expect(await request.reply(machines, gestures: gestures)["ok"] as? Bool != true)
        #expect(attached == ["vm-1"])
    }

    /// A send in a chat whose machine is paused wakes it with the Enter that sent the prompt: the
    /// attach takes that gesture's scope-add credit and leaves its grant for the prompt itself.
    @Test func aWakeLeavesTheSendsGrant() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        machines.attach = { _ in true }
        gestures.record()
        #expect(await AgentPaneCloudMachineRequest.attach(id: "vm-1").reply(machines, gestures: gestures)["ok"] as? Bool == true)
        #expect(gestures.consumeForSend())
    }

    /// Review of cmux#27031: a refresh that was superseded or failed leaves the earlier registry in
    /// place, so the reply is complete only when the App says the list is this read's own answer.
    @Test func theRecoveryListIsCompleteOnlyWhenTheAppSaysSo() async throws {
        let machines = AgentPaneCloudMachines()
        machines.recoveryList = { .init(signedIn: true, loaded: true, machines: [], account: ["user", nil]) }
        var value = try #require(await AgentPaneCloudMachineRequest.recoveryList.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(value["complete"] as? Bool == false)
        machines.recoveryList = { .init(signedIn: true, loaded: true, machines: [], account: ["user", nil], complete: true) }
        value = try #require(await AgentPaneCloudMachineRequest.recoveryList.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(value["complete"] as? Bool == true)
        // Cut at the row limit: never complete.
        let many = (0...AgentPaneCloudMachineRequest.maximumListed).map { AgentPaneCloudMachines.Machine(id: "vm-\($0)", name: "m", stage: "ready") }
        machines.recoveryList = { .init(signedIn: true, loaded: true, machines: many, account: ["user", nil], complete: true) }
        value = try #require(await AgentPaneCloudMachineRequest.recoveryList.reply(machines, gestures: AgentPaneUserGestures())["value"] as? [String: Any])
        #expect(value["complete"] as? Bool == false)
    }

    @Test func anAttachTheAppRefusesAfterItsFreshReadIsAVisibleFailure() async {
        let machines = AgentPaneCloudMachines()
        let gestures = AgentPaneUserGestures()
        machines.attach = { _ in await Task.yield(); return false }
        gestures.record(click: true)
        let reply = await AgentPaneCloudMachineRequest.attach(id: "vm-1").reply(machines, gestures: gestures)
        #expect(reply["ok"] as? Bool != true)
        #expect((reply["error"] as? [String: Any])?["code"] as? String == "unavailable")
    }

    @Test func inventoryKeepsPersonalAccountScopeAsJSONNull() async throws {
        let machines = AgentPaneCloudMachines()
        machines.list = { .init(signedIn: true, loaded: true, machines: [], account: ["user", nil]) }
        let reply = await AgentPaneCloudMachineRequest.list.reply(machines, gestures: AgentPaneUserGestures())
        #expect(JSONSerialization.isValidJSONObject(reply))
        let value = try #require(reply["value"] as? [String: Any])
        let account = try #require(value["account"] as? [Any])
        #expect(account[0] as? String == "user")
        #expect(account[1] is NSNull)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
