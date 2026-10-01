@testable import CmuxNextApp
import CmuxNextCloud
import Testing

/// Hand Off Machine shows what `cmux vm handoff` printed, with cmux-next's CLI verbs.
@MainActor
struct CloudHandoffTests {
    @Test func handoffNamesTheMachineStatusAndTheCommandsThatReachIt() {
        let machine = CloudMachine(id: "vm-42", provider: "freestyle", status: .paused, displayName: "build box")
        #expect(CloudHandlers.handoff(machine) == """
            build box (vm-42)
            provider: freestyle
            status: paused
            attach: cmux cloud open-machine --target machine:vm-42
            inspect: cmux cloud machine-tools --target machine:vm-42
            """)
    }
}
