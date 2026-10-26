import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBrowser
@testable import CmuxNextDaemon
import Foundation
import Testing

/// p08-startup-021: SSH, the remote localhost and the remote-terminal service are made on first use,
/// never in `AppServices.init` or at action binding; made late, each still gets what init gave it
/// (the policy, the install offer, the session observation), so a remote-terminal tab reconnects.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)))
struct RemoteServicesLazyTests {
    @Test func theAppMakesNoRemoteServiceAtLaunch() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        #expect(services.madeSSH == nil, "init or binding made SSH")
        #expect(services.madeRemoteLocalhost == nil, "init or binding made the remote localhost")
        #expect(services.madeRemoteTerminals == nil, "init or binding made the remote-terminal service")
        #expect(services.localhostBadge(for: TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser)),
                                        url: URL(string: "https://example.com"), engine: .webkit) == nil)
        #expect(services.madeRemoteLocalhost == nil, "a page that is not loopback made the remote localhost")
    }

    @Test func sshMadeLateTakesTheCurrentPolicyAndTheInstallOffer() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.registry.disabledFeatures = [.remoteHosts]
        let ssh = services.ssh
        #expect(services.madeSSH === ssh, "a second read makes a second SSHService")
        #expect(ssh.policyDisabled, "remote hosts were turned off before SSH was made")
        #expect(ssh.offerInstall != nil, "no install offer: remote.install never asks")
    }

    /// A remote-terminal tab on another machine attaches, shows its placeholder while that machine is
    /// gone, and attaches again when it comes back: the service made by the tab follows its session.
    @Test(.enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
    func aRemoteTerminalTabReconnectsWhenItsMachineComesBack() async throws {
        try await CrossMachineTabMoveTests.withMachines { world in
            let services = world.services
            #expect(services.madeRemoteTerminals == nil, "made before any remote-terminal tab")
            let machine = world.machine.daemon
            let session = try #require(machine.identity?.sessionID, "the other machine has no session id")
            let there = try await world.machineTab { $0.kind == .pty && $0.terminalID != nil }
            let ref = RemoteTerminalRef(sessionID: session, terminalID: try #require(there.terminalID), sessionName: "lazy-remote")
            let surface = try await world.macConnection.newRemoteTerminalTab(ref, in: world.macPane.handle).surface
            let tab = try await world.macTab { $0.surface == surface && $0.kind == .remoteTerminal }
            func attached() -> Bool {
                if case .terminal = services.remoteTerminals.content(for: tab, home: services.daemon) { return true }
                return false
            }
            try await PinnedPageTests.until({ attached() }, report: { "the remote-terminal tab never attached" })
            let made = try #require(services.madeRemoteTerminals)

            machine.shutdownConnection()
            try await PinnedPageTests.until({ services.cache.existingTerminal(tab.id) == nil },
                                            report: { "the gone machine's terminal is still mounted: the service follows no session" })
            #expect(!attached(), "attached to a machine that is gone")

            let socket = world.machineSocket
            machine.start(remote: { socket })
            try await PinnedPageTests.until({ attached() }, within: .seconds(60), report: { "the tab did not reconnect when its machine came back" })
            #expect(services.madeRemoteTerminals === made, "the service was made twice")
        }
    }
}
