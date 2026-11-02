import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextControl
import CmuxNextHomeEngine
import Foundation

/// The agent tabs' pane page and acpmux host (outside AgentTabStore, which is at its size limit).
@MainActor struct AgentTabPaneSource {
    /// The agent pane page and its acpmux host. Release loads only the
    /// bundled page; the dev server is for Debug and tagged builds
    /// (webviews/src/agent-session/acpmux/README.md). The page never opens a
    /// socket to acpmux: the host does (AgentPaneTransport), always with the
    /// bundled pane's origin, so even a dev server page reaches LocalApp and
    /// the app starts the daemon with no dev origin and no `--dev`
    /// (``AcpmuxEnvironment/resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)``). Only the
    /// browser dev slot, with no host, still needs both (dev-slot.sh). `daemons`: the app's local daemons.
    static func resolvePane(build: BuildIdentity?, environment: [String: String], showcase: Bool, daemons: AcpmuxLocalDaemons, peerApprover: AgentPanePeerApprover?)
        -> (source: AgentPaneSource?, host: any AgentPaneHostProviding) {
        #if DEBUG
        let allowsDevServer = true
        #else
        let allowsDevServer = false
        #endif
        let source = AgentPaneSource.resolve(
            environment: environment, bundledPage: AgentPaneView.bundledPage, allowsDevServer: allowsDevServer
        )
        if showcase || environment["CMUX_NEXT_AGENT_PANE_MOCK"] == "1" {
            return (source, MockAgentPaneHost())
        }
        let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true)
        let computerUse = ComputerUseHelperDaemon.shared
        // The helper v2 endpoint directory goes to every acpmux daemon this
        // app spawns, whatever the driver: it is constant for this app build,
        // so a daemon started while the driver is legacy finds the v2
        // endpoint after a switch to upstream. acpmux uses v2 only while
        // endpoint.json exists there (ComputerUseHelperV2).
        let upstreamEnvironment = ComputerUseHelperV2.childEnvironment(directory: computerUse.upstream.directory)
        let launch = LaunchIdentity.current()
        // NIGHTLY's Chief runs on this daemon (ChiefHome.usesAppAcpmux): acpmux's built-in Chief
        // presets read its Chief home from the daemon's own environment (chief_builtins.rs).
        let chief = ChiefHome.resolve(tag: build?.tag, environment: environment)
        let chiefMuxHome = chief.usesAppAcpmux ? chief.muxHome.path : nil
        // A DEV build with `CMUX_NEXT_ACPMUX_ATTACH` reads that home's daemon; its host never starts,
        // upgrades or hands that daemon off (``AcpmuxEnvironment/isAttached``).
        let attach = AcpmuxEnvironment.attachHome(build: build, environment: environment)
        let resolve: @Sendable () -> AcpmuxEnvironment? = {
            AcpmuxEnvironment.resolve(build: build, bundledBinDirectory: bin, environment: environment,
                                      launchEnvironment: launch.terminalEnvironment).map { own in
                var resolved = attach.map { own.attached(to: $0) } ?? own
                resolved.childEnvironment.merge(upstreamEnvironment) { $1 }
                if let chiefMuxHome { resolved.childEnvironment[AcpmuxEnvironment.chiefMuxHomeKey] = chiefMuxHome }
                return resolved
            }
        }
        computerUse.upstream.acpmux = { resolve().map { ($0.executable, $0.socketPath) } }
        // Machine consent for the helper comes from this app's own daemon socket only.
        computerUse.upstream.machineConsent = {
            guard let own = resolve() else { return nil }
            return await AcpmuxMachineConsent(socketPath: own.socketPath, executable: own.executable).current()
        }
        computerUse.upstream.consentRefused = { surface in
            guard let own = resolve() else { return }
            await AcpmuxMachineConsent(socketPath: own.socketPath, executable: own.executable)
                .recordRefusal(surface: surface)
        }
        let upstream = computerUse.upstream
        let host = AcpmuxHost(daemons: daemons, resolve: resolve,
                              computerUse: { computerUse.childEnvironment },
                              daemonReady: { socket in await upstream.registerAcpmuxDaemon(acpmuxSocket: socket) }, peerApprover: peerApprover)
        // A replaced agent token reaches the running acpmux now, not when a pane reconnects.
        computerUse.onEndpointChange = { _ in
            // task-owner: one enrollment per endpoint change; each reads the current endpoint, so the last one wins.
            Task { await host.computerUseChanged() }
        }
        return (source, host)
    }
}
