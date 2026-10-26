import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextRemoteLocalhostService
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// A machine wears one color (MachineColor, #22763), hashed from its sidebar name: a tab's
/// machine badge takes it from `MachineRegistry.tabColorName`, so remote terminals and
/// remote-localhost browser tabs match the machine's sidebar rows and composer chip even
/// where the badge shows other text. An SSH host named "lab" at leo@huge-blue badges its
/// tabs "huge-blue"; they hashed "huge-blue" and wore another color than the "lab" rows.
@MainActor
struct TabMachineColorTests {
    static func sshMachine(_ machines: MachineRegistry) throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: "leo@huge-blue.tail1.ts.net")).named("lab")
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/cn-tab-machine-color-unused")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        machines.add(session)
        return session
    }

    @Test func anSSHHostsTabBadgeTakesTheColorOfItsSidebarName() throws {
        let machines = MachineRegistry(local: DaemonService())
        let id = try Self.sshMachine(machines).machineID
        let (badge, sidebar) = (machines.machineBadge(id), machines.machineName(id))
        #expect(badge == "huge-blue" && sidebar == "lab", "the badge shows the destination, the sidebar the label")
        #expect(machines.tabColorName(id, badge: badge) == "lab", "a terminal tab on the host")
        // A remote-localhost browser tab badges the machine's localhost with the same short name.
        let localhost = RemoteLocalhostService(machines: machines, environment: [:])
        let browser = localhost.machineName(of: try #require(machines.anyDaemon(machine: id)))
        #expect(machines.tabColorName(id, badge: browser) == "lab", "a browser tab seeing the host's localhost")
    }

    @Test func otherBadgesKeepTheirOwnTextsColor() throws {
        let machines = MachineRegistry(local: DaemonService())
        let id = try Self.sshMachine(machines).machineID
        #expect(machines.tabColorName(id, badge: "this Mac") == nil, "a This Mac chip names no machine of the tree")
        #expect(machines.tabColorName(id, badge: nil) == nil)
        #expect(machines.tabColorName("vm-unknown", badge: "vm-unknown") == nil, "a machine not known here")
        #expect(machines.tabColorName(MachineRegistry.localID, badge: "huge-blue") == nil)
        #expect(machines.tabColorName(nil, badge: "huge-blue") == nil)
    }
}
