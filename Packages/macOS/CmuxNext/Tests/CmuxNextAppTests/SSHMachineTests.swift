import CmuxNextDaemon
import CmuxNextRemote
import CmuxNextSidebar
import Foundation
import Testing
@testable import CmuxNextApp

/// SSH machines in the app: the saved-host record in the session registry,
/// the sidebar status of each link state, and machine resolution by name.
@MainActor @Suite struct SSHMachineTests {
    func session(_ destination: String = "dev@build-box.local", name: String = "main") throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: destination), session: name)
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ssh-tests-\(UUID().uuidString)"))
        return SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: paths, environment: { [:] })
    }

    @Test func registryTransportRoundTripsTheRouteAndTheLaunchChoice() throws {
        let machine = try session("dev@build-box.local:2200", name: "work")
        machine.autoConnect = false
        let transport = SSHService.transport(machine)
        let fields = try #require(SSHService.fields(transport))
        #expect(fields["kind"] == "ssh")
        #expect(fields["destination"] == "dev@build-box.local:2200")
        #expect(fields["session"] == "work")
        #expect(fields["connect"] == "false")
        #expect(SSHHost(transportFields: fields)?.machineID == machine.machineID)
        #expect(!fields.values.contains { $0.localizedCaseInsensitiveContains("password") })
    }

    @Test func sidebarStatusFollowsTheLinkState() throws {
        let machine = try session()
        let cases: [(SSHConnectionMachine.Status, SidebarMachine.Status)] = [
            (.offline, .offline),
            (.connecting, .connecting),
            (.authFailed("Permission denied (publickey)."), .authFailed),
            (.hostKeyUntrusted("Host key verification failed."), .authFailed),
            (.unreachable("No route to host"), .unreachable),
            (.needsInstall(.missing), .installRequired),
            (.needsInstall(.protocolMismatch(remote: 4, local: 5)), .updateRequired),
            (.installing, .installing),
            (.installFailed("checksum"), .installRequired),
            // Link up, daemon not answered yet.
            (.connected, .connecting),
        ]
        for (link, expected) in cases {
            machine.linkStatus = link
            #expect(SidebarBridge.sshStatus(machine, compatibility: nil) == expected, "\(link)")
        }
    }

    @Test func headerNamesTheMachineAndExplainsAFailure() throws {
        let machine = try session("dev@build-box.local", name: "work")
        machine.linkStatus = .authFailed("Permission denied (publickey).")
        let header = SidebarBridge.sshMachine(machine, machines: MachineRegistry(local: DaemonService()))
        #expect(header.name == "build-box/work")
        #expect(header.kind == .ssh)
        #expect(header.status == .authFailed)
        #expect(header.detail?.contains("dev@build-box.local") == true)
        #expect(header.detail?.contains("Permission denied (publickey).") == true)
    }

    /// cx-zdh8 (m1max preflight): SSH works but the machine's cmux-tui
    /// daemon does not start (an old session db), so every daemon handshake
    /// ends with "link closed during handshake". The header showed
    /// Connecting for ever; it now shows the failure and the daemon's own
    /// error, and Copy SSH Error copies it.
    @Test func aDaemonThatDoesNotStartIsAFailureNotConnecting() throws {
        #expect(SidebarBridge.sshStatus(link: .connected, startupFailed: true, daemonConnected: false, compatibility: nil) == .failed)
        #expect(SidebarBridge.sshStatus(link: .connecting, startupFailed: true, daemonConnected: false, compatibility: nil) == .failed)
        #expect(SidebarBridge.sshStatus(link: .connected, startupFailed: false, daemonConnected: false, compatibility: nil) == .connecting,
                "within the first-connect deadline it still connects")
        #expect(SidebarBridge.sshStatus(link: .connected, startupFailed: false, daemonConnected: true, compatibility: nil) == .connected)
        #expect(SidebarMachine.Status.failed.needsAttention)
    }

    @Test func aRemoteFailureOfTheLinkIsAFailure() throws {
        let machine = try session()
        machine.linkStatus = .failed("the remote shell gave no probe output")
        #expect(SidebarBridge.sshStatus(machine, compatibility: nil) == .failed)
        #expect(RemoteStrings.sshError(machine) == "the remote shell gave no probe output")
    }

    @Test func theDaemonErrorReachesTheHeaderAndCopySSHError() throws {
        let machine = try session()
        machine.linkStatus = .connected
        machine.daemonFailure = "cmux-tui connection closed: link closed during handshake\nError: table session_journal has no column named actor"
        let detail = try #require(RemoteStrings.detail(machine))
        #expect(detail.contains("session_journal has no column named actor"))
        #expect(RemoteStrings.sshError(machine)?.contains("session_journal has no column named actor") == true)
        machine.daemonFailure = nil
        #expect(RemoteStrings.sshError(machine) == nil)
    }

    @Test func machinesResolveByIDNameOrDestination() throws {
        let registry = MachineRegistry(local: DaemonService())
        let box = try session("dev@build-box.local")
        let gpu = try session("gpu1")
        registry.add(box)
        registry.add(gpu)
        #expect(registry.sshSession(box.machineID) === box)
        #expect(registry.daemon(machine: gpu.machineID) === gpu.daemon)
        #expect(registry.daemons.count == 3)
        #expect(registry.machineName(box.machineID) == "build-box")
        #expect(registry.removeSSH(gpu.machineID) === gpu)
        #expect(registry.daemons.count == 2)
    }
}
