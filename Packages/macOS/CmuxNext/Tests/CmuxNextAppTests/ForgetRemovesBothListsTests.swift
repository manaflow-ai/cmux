@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextServer
import CmuxNextWakeups
import Foundation
import Testing

/// HQ #4877 break 8: a machine added with Add Device is in two lists, the sidebar's SSH machines
/// and the acpmux peers. Forget takes it out of both once its Undo toast ends (Undo needs nothing
/// more: the peer goes only when the Forget is written), and Settings > Devices Remove of a peer
/// forgets the SSH machine at the same route. Only an exact route match is taken.
@MainActor @Suite(.serialized) struct ForgetRemovesBothListsTests {
    static func session(_ text: String, session name: String = RemoteSessionName.defaultName) throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: text), session: name)
        return SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                 paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/forget-both-tests")),
                                 environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    static func service() -> SSHService {
        SSHService(machines: MachineRegistry(local: DaemonService()), bundleID: nil, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    @Test func aPeerIsTheMachinesOnlyOnAnExactRoute() throws {
        let leo = try SSHDestination(parsing: "leo@studio.example.ts.net")
        #expect(SSHPeerForgets.reaches(leo, peer: "leo@studio.example.ts.net"))
        #expect(SSHPeerForgets.reaches(leo, peer: "leo@Studio.Example.ts.net"), "host names compare without case")
        #expect(!SSHPeerForgets.reaches(leo, peer: "studio.example.ts.net"), "another user is another route")
        #expect(!SSHPeerForgets.reaches(leo, peer: "root@studio.example.ts.net"))
        #expect(!SSHPeerForgets.reaches(leo, peer: "leo@studio"), "a short name is not the same host")
        #expect(!SSHPeerForgets.reaches(try SSHDestination(parsing: "leo@studio.example.ts.net:2222"), peer: "leo@studio.example.ts.net"),
                "a machine on another ssh port is never the peer")
        #expect(SSHPeerForgets.reaches(try SSHDestination(parsing: "leo@[fd7a::2]"), peer: "leo@[fd7a::2]"))
    }

    @Test func forgetRemovesThePeerOnlyWhenItIsWritten() async throws {
        let ssh = Self.service()
        let session = try Self.session("leo@studio.example.ts.net")
        ssh.machines.add(session)
        var picked: [[String]] = []
        ssh.peerForgets.remove = { matches in
            picked.append(["leo@studio.example.ts.net", "studio.example.ts.net", "leo@gpu-west"].filter(matches))
        }
        let pending = ssh.hide(session)
        #expect(picked.isEmpty, "the Undo toast is still up: the peer stays")
        ssh.unhide(pending)
        await ssh.commitForget(pending)
        #expect(picked.isEmpty, "an undone Forget writes nothing, so the peer stays")

        ssh.machines.add(session)
        let again = ssh.hide(session)
        await ssh.commitForget(again)
        #expect(picked == [["leo@studio.example.ts.net"]], "the written Forget takes out the peer at its route, and only that one")
        #expect(ssh.machines.sshSession(session.machineID) == nil, "and the SSH machine is out of the list too")
    }

    /// The peer removal on its own (SSHPeerForgets, CmuxNextServer): a Forget whose Undo shows keeps
    /// its route's peer until it ends; a connect of the machine clears its marks; only the route's
    /// peer is picked, and only while the caller says the Forget holds.
    @Test func thePeerRemovalKeepsAShownUndosPeerAndPicksOnlyItsRoute() async throws {
        let forgets = SSHPeerForgets(cli: nil, environment: { [:] })
        #expect(forgets.remove == nil, "no cmux-tui: no peer is removed")
        var picked: [String] = []
        forgets.remove = { matches in picked += ["leo@studio.example.ts.net", "leo@gpu-west"].filter(matches) }
        let route = try SSHDestination(parsing: "leo@studio.example.ts.net")
        let shown = forgets.hide(machineID: "m1", label: "studio", destination: route, fields: [:], sessionID: nil)
        await forgets.removePeers(at: route) { true }
        #expect(picked.isEmpty, "a Forget of that route still shows its Undo")
        forgets.ended(shown)
        await forgets.removePeers(at: route) { false }
        #expect(picked.isEmpty, "the caller says the Forget no longer holds")
        await forgets.removePeers(at: route) { true }
        #expect(picked == ["leo@studio.example.ts.net"])
        _ = forgets.hide(machineID: "m1", label: "studio", destination: route, fields: [:], sessionID: nil)
        forgets.connected("m1")
        await forgets.removePeers(at: route) { true }
        #expect(picked.count == 2, "a connect of the machine clears its Forget's mark")
    }

    @Test func forgetKeepsThePeerWhileAnotherSessionReachesTheSameRoute() async throws {
        let ssh = Self.service()
        let main = try Self.session("leo@studio.example.ts.net")
        let work = try Self.session("leo@studio.example.ts.net", session: "work")
        ssh.machines.add(main)
        ssh.machines.add(work)
        var calls = 0
        ssh.peerForgets.remove = { matches in calls += ["leo@studio.example.ts.net"].filter(matches).count }
        await ssh.forget(work)
        #expect(calls == 0, "the default session still uses that peer")
        await ssh.forget(main)
        #expect(calls == 1)
    }

    /// Two sessions on one host forgotten in a row: the second toast ends the first (writing it)
    /// while the second's Undo still shows, so the shared peer stays until that one is written.
    @Test func aForgetWhoseUndoStillShowsKeepsThePeer() async throws {
        let ssh = Self.service()
        let main = try Self.session("leo@studio.example.ts.net")
        let work = try Self.session("leo@studio.example.ts.net", session: "work")
        ssh.machines.add(main)
        ssh.machines.add(work)
        var calls = 0
        ssh.peerForgets.remove = { matches in calls += ["leo@studio.example.ts.net"].filter(matches).count }
        let first = ssh.hide(work)
        let second = ssh.hide(main)
        await ssh.commitForget(first)
        #expect(calls == 0, "the second Forget's Undo would bring back a machine with no peer")
        await ssh.commitForget(second)
        #expect(calls == 1, "written with nothing else on the route: the peer goes")
    }

    /// A reconnect while the peer removal runs (between `host ls` and each `host rm`) keeps the peer:
    /// the predicate is asked again right before each remove.
    @Test func aReconnectDuringThePeerRemovalKeepsThePeer() async throws {
        let ssh = Self.service()
        let session = try Self.session("leo@studio.example.ts.net")
        ssh.machines.add(session)
        var removed: [String] = []
        ssh.peerForgets.remove = { matches in
            ssh.machines.add(session) // the person connects it again while `host ls` runs
            removed += ["leo@studio.example.ts.net"].filter(matches)
        }
        await ssh.commitForget(ssh.hide(session))
        #expect(removed.isEmpty)
    }

    @Test func peersAreReadFromTheHostListBySSHRoute() {
        let json = #"""
        {"peers":[{"name":"studio","url":"ssh://leo@studio.example.ts.net","connected":true},
                  {"name":"box","url":"ssh://box.example.ts.net:47900"},
                  {"name":"lan","url":"ws://10.0.0.4:47811"},
                  {"name":"","url":"ssh://nameless"}]}
        """#
        #expect(DeviceDirectory.sshPeers(Data(json.utf8)) == [
            DeviceDirectory.SSHPeer(name: "studio", destination: "leo@studio.example.ts.net"),
            DeviceDirectory.SSHPeer(name: "box", destination: "box.example.ts.net"),
        ])
    }

    @Test func devicesRemoveOfAPeerForgetsItsSSHMachineAndForgetRemovesItsPeer() async {
        final class CLI {
            var calls: [[String]] = []
            func run(_ args: [String]) -> Data? {
                calls.append(args)
                switch args.prefix(3).joined(separator: " ") {
                case "acp host ls":
                    return Data(#"{"peers":[{"name":"studio","url":"ssh://leo@studio.example.ts.net"},{"name":"gpu","url":"ssh://gpu"}]}"#.utf8)
                case "device remove peer:studio", "acp host rm": return Data("{}".utf8)
                default: return args.first == "device" && args[1] != "remove" ? Data("{}".utf8) : nil
                }
            }
        }
        let cli = CLI()
        var forgotten: [String] = []
        let directory = DeviceDirectory(run: { cli.run($0) }, removePhone: { _ in }, peerRemoved: { forgotten.append($0) })
        #expect(await directory.remove(id: "peer:studio") == nil)
        #expect(forgotten == ["leo@studio.example.ts.net"], "the SSH machine at the removed peer's route is forgotten too")
        #expect(await directory.remove(id: "peer:gpu") != nil, "that remove fails in this fake")
        #expect(forgotten.count == 1, "a failed remove forgets nothing")
        #expect(await directory.remove(id: "grant:new@manaflow.ai") != nil)
        #expect(!cli.calls.contains(["acp", "host", "rm", "studio", "--json"]))

        cli.calls = []
        await directory.removePeers { $0 == "leo@studio.example.ts.net" }
        #expect(cli.calls.contains(["acp", "host", "rm", "studio", "--json"]))
        #expect(!cli.calls.contains(["acp", "host", "rm", "gpu", "--json"]), "a peer at another route stays")
    }
}
