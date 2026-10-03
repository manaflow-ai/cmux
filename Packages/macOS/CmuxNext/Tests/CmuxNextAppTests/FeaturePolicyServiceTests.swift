import CmuxNextActions
import CmuxNextDaemon
import CmuxNextRemote
import Foundation
import Testing
@testable import CmuxNextApp

/// DisabledFeatures past the registry (plans/cmux-next/enterprise.md
/// P17-1b): turning remote hosts off ends this Mac's SSH links, refuses
/// reconnects and keeps the machines (and the remote daemons) in place;
/// turning it on again reconnects what was connecting.
@MainActor @Suite struct FeaturePolicyServiceTests {
    func services() throws -> (AppServices, SSHMachineSession) {
        let services = AppServices(environment: AppEnvironment.current([:]))
        let host = try SSHHost(destination: SSHDestination(parsing: "dev@build-box.local"), session: "main")
        let paths = SSHPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("policy-\(UUID().uuidString)"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"), paths: paths, environment: { [:] })
        services.machines.add(session)
        return (services, session)
    }

    @Test func turningRemoteHostsOffEndsAndRefusesSSHLinks() async throws {
        let (services, session) = try services()
        session.autoConnect = true
        services.ssh.applyPolicy(disabled: true)
        #expect(session.daemon.policyBlock.isBlocked)
        #expect(session.linkStatus == .offline)
        #expect(session.autoConnect, "the user's choice to connect survives the policy")
        #expect(services.machines.ssh.contains { $0 === session }, "the machine and its workspaces stay")
        await #expect(throws: DaemonError.self) { _ = try await session.daemon.endpoint() }
        #expect(throws: ActionFailure.self) {
            try services.ssh.connect(destination: "dev@other.local", session: nil, offerInstall: false)
        }
        services.ssh.reconnect(session)
        #expect(session.linkStatus == .offline)

        services.ssh.applyPolicy(disabled: false)
        #expect(!session.daemon.policyBlock.isBlocked)
        #expect(session.linkStatus == .connecting)
    }

    @Test func aTurnedOffMachineIsNotResolvable() throws {
        let (services, session) = try services()
        #expect(services.machines.daemon(machine: session.machineID) != nil)
        services.registry.disabledFeatures = [.remoteHosts]
        #expect(services.machines.daemon(machine: session.machineID) == nil)
        #expect(services.machines.daemon(machine: MachineRegistry.localID) != nil)
    }

    @Test func turningCloudOffRefusesNewMachines() async throws {
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.cloud.applyPolicy(disabled: true)
        #expect(services.cloud.unavailableReason == RefusalStrings.turnedOffByOrganization)
        await #expect(throws: ActionFailure.self) { _ = try await services.cloud.createMachine(name: nil) }
    }
}
