import CmuxNextCloud
import Testing

/// New Cloud Workspace with no machine named, several Cloud machines and none in view, opens on a
/// machine the person already has (``CloudMachine/takesUnnamedWorkspaces``) rather than start and
/// bill a new VM (Lawrence msg 1334). A failed, destroyed or person-paused machine is never picked.
struct CloudMachineUnnamedWorkspaceTests {
    @Test(arguments: [
        (CloudMachine.Status.running, nil as CloudMachine.PauseReason?, true),
        (.provisioning, nil, true),
        (.starting, nil, false),
        (.paused, .idle, true),
        (.paused, .user, false),
        (.paused, nil, false),
        (.failed, nil, false),
        (.destroyed, nil, false),
        (.unknown, nil, false),
    ])
    func picksOnlyAMachineThatRunsOrResumesFromIdle(status: CloudMachine.Status, reason: CloudMachine.PauseReason?, takes: Bool) {
        let machine = CloudMachine(id: "vm-1", status: status, pauseReason: reason)
        #expect(machine.takesUnnamedWorkspaces == takes)
    }

    @Test(arguments: [CloudMachine.Status.pausing, .starting, .deleting])
    func aPendingMutationNeverBecomesAnUnnamedTarget(change: CloudMachine.Status) {
        var machine = CloudMachine(id: "vm-1", status: .running)
        machine.pendingChange = change
        #expect(!machine.takesUnnamedWorkspaces)
    }
}
