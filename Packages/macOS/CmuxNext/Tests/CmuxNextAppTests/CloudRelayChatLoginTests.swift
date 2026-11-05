import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudCredentials
import Foundation
import Testing

/// `cmux cloud relay-chat` gives the machine the person's harness login before it sends, as `cloud start-session`
/// does (Leo: "we have the daemon, we have the token, we have the thing that can just send it over the
/// authentication"). A chat that `cloud start-chat` sent first over the relay reached a guest with no Claude login
/// and answered "Claude is not signed in here".
@MainActor @Suite(.serialized)
struct CloudRelayChatLoginTests {
    /// A fresh Cloud machine with nothing inherited: no start-session ran on it first.
    static func fixture() -> (services: AppServices, machine: CloudMachineSession) {
        let services = MachineIconTests.services()
        AppActions.bind(services)
        let id = "vm_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(20)
        return (services, MachineIconTests.cloudMachine(services, id: id))
    }

    static func invocation(_ machine: CloudMachineSession, origin: ActionOrigin = .cli) -> ActionInvocation {
        ActionInvocation(target: ActionTargetRef(kind: .machine, id: machine.machineID),
                         arguments: ["agent": .string("claude"), "prompt": .string("hello")], origin: origin)
    }

    /// The app's own binding, with the app's own login step: a CLI relay chat on a fresh machine runs that step
    /// (its decision is on the machine's row) before the relay is asked. Red on a base that sends with no login step.
    @Test func aCLIRelayChatRunsTheHarnessLoginStepFirst() async throws {
        let f = Self.fixture()
        #expect(f.machine.harnessLogin == nil)
        let invoke = try #require(f.services.registry.action(for: "cloudRelayChat")?.invoke, "cloudRelayChat is not bound")
        let run = f.services.registry.capturingRun { invoke(Self.invocation(f.machine)) }
        let task = try #require(run.results.first, "cloud relay chat tracked no result")
        _ = await task.value
        #expect(f.machine.harnessLogin?.provider == .claude, "the relay chat was sent with no harness login step")
    }
}
