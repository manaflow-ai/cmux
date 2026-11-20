import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextCloud
import Foundation
import Testing

/// Internet Access… (`cloud set-network-access`): its CLI action names the three levels, and a
/// Cloud app server machine, which has no network policy yet, is refused.
@MainActor @Suite(.serialized)
struct CloudNetworkAccessTests {
    @Test func theSettingIsACLIActionWithExactlyTheThreeLevels() throws {
        let services = MachineIconTests.services()
        let descriptor = try #require(services.registry.descriptor(for: "cloudSetNetworkAccess"))
        #expect(descriptor.cliName == "cloud set-network-access")
        #expect(descriptor.targets == [.machine])
        #expect(descriptor.waitsForResult, "a CLI or MCP call waits for the server's answer, not the 2 s default")
        #expect(descriptor.surfaces.contains(.contextMenu))
        let argument = try #require(descriptor.arguments.first)
        #expect(argument.name == "access")
        guard case .enumeration(let cases) = argument.kind else {
            Issue.record("access is not a choice")
            return
        }
        #expect(cases.map(\.value) == ["full", "trusted", "none"])
    }

    /// A machine on the app server link has no network policy: the action is refused.
    @Test func theAppServerLinkRefuses() {
        let services = MachineIconTests.services()
        let session = MachineIconTests.cloudMachine(services, id: "vm-net-app-link")
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .machine, id: session.machineID),
                                          arguments: ["access": .string("none")], origin: .cli)
        #expect(throws: ActionFailure.self) {
            try CloudNetworkAccessActions.set(invocation, AppActionContext(services: services))
        }
    }
}
