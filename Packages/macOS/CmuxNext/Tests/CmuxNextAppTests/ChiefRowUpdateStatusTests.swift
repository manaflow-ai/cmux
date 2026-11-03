@testable import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextRemote
@testable import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing
@testable import CmuxNextApp

/// The sidebar's Chief row (the local Chief owner daemon, shown on the paired-server path) never
/// says "Update available": updates live in the sidebar footer and the update card. The Chief
/// owner outlives an app update and keeps the older build's capabilities, so its daemon reads
/// limited, and the row used to wear a green dot and "Update available" next to "Chief".
@MainActor
struct ChiefRowUpdateStatusTests {
    /// A server on this Mac whose daemon serves every required capability and no optional one.
    static func olderServer(_ reach: ServerReach) throws -> (ServerMachineSession, MachineRegistry) {
        let machines = MachineRegistry(local: DaemonService())
        let session = ServerMachineSession(reach: reach, binary: nil,
                                           paths: .init(root: URL(fileURLWithPath: "/private/tmp/cn-chief-row-unused")),
                                           environment: { [:] }, localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let list = DaemonCapability.required.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"app":"cmux-tui","protocol":1,"session":"cmux-chief-abcd1234","generation":"g1","capabilities":["# + list + "]}"
        let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
        session.daemon.store.noteHandshake(identity)
        session.daemon.store.connectionState = .connected(identity)
        machines.add(session)
        return (session, machines)
    }

    @Test func theChiefRowOfAnOlderOwnerDaemonSaysNoUpdate() throws {
        let reach = try ServerReach.localChief(homeID: "abcd1234", socket: "/private/tmp/cn-chief-row.sock", name: "Chief")
        #expect(reach.isLocalChief)
        let (chief, machines) = try Self.olderServer(reach)
        #expect(machines.compatibility(of: chief.daemon)?.level == .limited, "the fixture is an older owner daemon")
        let header = chief.sidebarMachine(machines: machines)
        #expect(header.status == .connected, "the Chief row reads connected, never Update available")
        #expect(SectionHeaderRowView.statusText(header.status, hostGroup: false) == nil, "no words beside the Chief's name")
    }

    @Test func aServerOnThisMacWithAnOlderDaemonSaysNoUpdate() throws {
        let reach = try ServerReach(hostID: "host_minirow01", installID: "inst_minirow02", name: "Mini",
                                    route: .unix("/private/tmp/cn-chief-row-2.sock"))
        #expect(!reach.isLocalChief)
        let (server, machines) = try Self.olderServer(reach)
        #expect(server.sidebarMachine(machines: machines).status == .connected)
    }

    /// An overlay server is another machine: its older daemon still says Update available.
    @Test func anOverlayServerWithAnOlderDaemonKeepsItsStatus() throws {
        let reach = try ServerReach(hostID: "host_minirow03", installID: "inst_minirow04", name: "Mini",
                                    route: .overlay(linkSocket: "/private/tmp/cn-chief-row-3.sock"))
        let (server, machines) = try Self.olderServer(reach)
        #expect(server.sidebarMachine(machines: machines).status == .updateAvailable)
    }
}
