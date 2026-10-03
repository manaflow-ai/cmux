import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

/// Terminals and displays retain their machine boundary. Browser tabs remain
/// portable while retaining their original resource identity and access route.
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

    @Test("Browser resources are portable, but cannot carry a foreign terminal through the gate")
    func portableBrowsers() {
        let policy = SurfaceOwnershipPolicy(cloudMachine: teamAMachine)
        for machine in [SurfaceMachineID.local, teamAMachine, teamBMachine] {
            let browser = SurfaceResourceID(machine: machine, kind: .browser, key: "browser")
            #expect(policy.rejection(for: [browser]) == nil)
            let terminal = SurfaceResourceID(machine: teamBMachine, kind: .terminal, key: "terminal")
            #expect(policy.rejection(for: [browser, terminal]) == .cloudMachineMismatch)
        }
        #expect(policy.rejection(for: [SurfaceResourceID]()) == .cloudMachineMismatch)
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
