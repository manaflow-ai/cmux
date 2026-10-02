import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

/// Surfaces from several teams can be open at once. Team is never an input to
/// the drop rule: a Cloud workspace belongs to one machine, and a machine
/// belongs to one team, so the machine check already excludes every other team.
@Suite("Surface ownership across teams")
struct SurfaceOwnershipPolicyCrossTeamTests {
    private let teamAMachine = SurfaceMachineID.cloud("vm-team-a")
    private let teamBMachine = SurfaceMachineID.cloud("vm-team-b")

    @Test("A Cloud workspace accepts only its own machine, never another team's")
    func cloudWorkspaceRejectsAnotherTeam() {
        let teamAWorkspace = SurfaceOwnershipPolicy(cloudMachine: teamAMachine)
        #expect(teamAWorkspace.rejection(for: teamAMachine) == nil)
        #expect(teamAWorkspace.rejection(for: teamBMachine) == .cloudMachineMismatch)
        #expect(teamAWorkspace.rejection(for: .local) == .cloudMachineMismatch)
        #expect(teamAWorkspace.rejection(for: [teamAMachine, teamBMachine]) == .cloudMachineMismatch)
        let teamBTerminal = SurfaceResourceID(machine: teamBMachine, kind: .terminal, key: "term_b")
        #expect(teamAWorkspace.rejection(for: [teamBTerminal]) == .cloudMachineMismatch)
    }

    @Test("A local workspace accepts surfaces from every team")
    func localWorkspaceAcceptsEveryTeam() {
        let local = SurfaceOwnershipPolicy(cloudMachine: nil)
        #expect(local.rejection(for: teamAMachine) == nil)
        #expect(local.rejection(for: teamBMachine) == nil)
        #expect(local.rejection(for: [teamAMachine, teamBMachine, .local]) == nil)
        let resources = [
            SurfaceResourceID(machine: teamAMachine, kind: .terminal, key: "term_a"),
            SurfaceResourceID(machine: teamBMachine, kind: .display, key: "display"),
        ]
        #expect(local.rejection(for: resources) == nil)
    }
}
