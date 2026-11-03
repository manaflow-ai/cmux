import CmuxNextCloud
import Testing

/// `cmux cloud new-workspace` from a CLI or agent with no `--target` makes the workspace's own new
/// machine. It once opened on a team's fleet lane VM: the focused window's machine, else the only
/// one, else the first connected one (design/cloud.md, "One workspace per small machine", rule 1).
struct CloudNewWorkspaceMachineTests {
    @Test func aNamedMachineIsUsedByAnyCaller() {
        #expect(CloudNewWorkspaceMachine.pick(named: "vm-1", byPerson: false, focused: "vm-2") == .named("vm-1"))
        #expect(CloudNewWorkspaceMachine.pick(named: "vm-1", byPerson: true, focused: "vm-2") == .named("vm-1"))
    }

    @Test func aCLIOrAgentRunWithNoTargetGetsANewMachine() {
        // The focused window's machine is someone's workspace (or a fleet lane VM): never taken.
        #expect(CloudNewWorkspaceMachine.pick(named: nil, byPerson: false, focused: "vm-fleet") == .new)
        #expect(CloudNewWorkspaceMachine.pick(named: nil, byPerson: false, focused: nil) == .new)
        #expect(CloudNewWorkspaceMachine.pick(named: "", byPerson: false, focused: nil) == .new)
    }

    @Test func thePersonsGestureOpensOnTheMachineTheirWindowShows() {
        #expect(CloudNewWorkspaceMachine.pick(named: nil, byPerson: true, focused: "vm-2") == .focused("vm-2"))
    }

    @Test func thePersonWithNoMachineInViewGetsANewOne() {
        // No "the only one" or "first connected" fallback: those can be a teammate's or a fleet VM.
        #expect(CloudNewWorkspaceMachine.pick(named: nil, byPerson: true, focused: nil) == .new)
        #expect(CloudNewWorkspaceMachine.pick(named: nil, byPerson: true, focused: "") == .new)
    }
}
