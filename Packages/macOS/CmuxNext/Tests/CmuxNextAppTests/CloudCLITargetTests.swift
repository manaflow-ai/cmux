import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import Foundation
import Testing

/// Cloud machine actions from the CLI, MCP, a script, a page or another client
/// act only on the machine they name (`--target machine:<id>`). Before, a run
/// with no target fell back to the machine the person's window showed, else the
/// only machine, so an agent's `cloud kill-machine --confirm true` could kill
/// the machine the person was looking at. A person's own gesture keeps the
/// fallback. A non-person run also gets its answer back as `action.run`'s
/// `result` (`cloud new-machine` answers with the new machine's id).
@MainActor @Suite(.serialized)
struct CloudCLITargetTests {
    static func fixture() -> (services: AppServices, context: AppActionContext, session: CloudMachineSession) {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-cli-\(UUID().uuidString.prefix(8))")
        return (services, AppActionContext(services: services), session)
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatIsNotThePersonsNeedsAMachineTarget(origin: ActionOrigin) {
        let f = Self.fixture()
        #expect(f.services.machines.cloud.count == 1, "the only machine is the old fallback")
        #expect(throws: ActionFailure(message: CloudStrings.noMachine)) {
            try CloudHandlers.machine(ActionInvocation(origin: origin), f.context)
        }
    }

    @Test(arguments: [ActionOrigin.cli, .mcp, .script, .remote, .page])
    func aRunThatNamesItsMachineActsOnIt(origin: ActionOrigin) throws {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: f.session.machineID), origin: origin)
        #expect(try CloudHandlers.machine(invocation, f.context) === f.session)
    }

    @Test func aRunNamingAMachineThatIsNotThereIsNotFound() {
        let f = Self.fixture()
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: "vm-gone"), origin: .cli)
        do {
            _ = try CloudHandlers.machine(invocation, f.context)
            Issue.record("a missing machine resolved")
        } catch let failure as ActionFailure {
            #expect(failure.isNotFound)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func thePersonsGestureKeepsTheOnlyMachineFallback() throws {
        let f = Self.fixture()
        #expect(try CloudHandlers.machine(ActionInvocation(origin: .user), f.context) === f.session)
    }
}
