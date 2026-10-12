import CmuxCloud
import Testing

@Suite("Cloud computer-use readiness")
struct CloudComputerUseTests {
    @Test("readiness survives the VM summary to sidebar snapshot projection")
    func readinessProjectsToSnapshot() {
        let readiness = VMComputerUseReadiness(
            status: .failed,
            errorCode: "vm_failed",
            errorMessage: "The desktop machine failed to start."
        )
        let summary = VMSummary(
            id: "vm-desktop",
            provider: "freestyle",
            status: "failed",
            image: "cmux-devbox",
            createdAt: 0,
            kind: .desktop,
            computerUse: readiness
        )

        let snapshot = MachineSnapshotBuilder.snapshot(from: summary)
        #expect(snapshot.computerUse == readiness)
        #expect(snapshot.isDesktop)
    }

    @Test("older summaries keep readiness absent")
    func olderSummaryStaysOptional() {
        let summary = VMSummary(
            id: "vm-legacy",
            provider: "freestyle",
            status: "running",
            image: "cmux-devbox",
            createdAt: 0
        )

        #expect(summary.computerUse == nil)
        #expect(MachineSnapshotBuilder.snapshot(from: summary).computerUse == nil)
    }
}
