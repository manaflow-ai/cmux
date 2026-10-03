import CmuxNextControl
import CmuxNextDaemon
import CmuxNextTerminal
import Foundation

/// How this process was launched. Identity (bundle, tag, control socket)
/// comes from the app bundle only (`LaunchIdentity`); inherited `CMUX_*`
/// variables were stripped in `CmuxNextApp.shared.main` before this is read.
struct AppEnvironment: Sendable {
    let launch: LaunchIdentity
    /// `CMUX_NEXT_NO_ACTIVATE=1`: never take focus from the user's frontmost
    /// app (agent preflights and background launches). Windows open ordered
    /// back and the app never activates itself.
    let noActivate: Bool
    /// DEBUG showcase profile requested by `--showcase` or `CMUX_NEXT_SHOWCASE=1`.
    let showcase: Bool
    /// `CMUX_NEXT_TEST_WINDOW_SCREEN` / `CMUX_NEXT_TEST_WINDOW_FRAME` with
    /// no-activate: where windows open for agent screenshots.
    let testWindow: TestWindowPlacement?
    /// Mark this run for crash recovery (`AppRunMarker`): only the real app
    /// process, never tests that build `AppServices`.
    var marksRun = false
    /// What every local terminal of this app gets on top of its filtered
    /// login environment: the launch identity (`LaunchIdentity`) and the
    /// terminal identity Ghostty gives its shells (`TerminalEnvironment.instance.ghostty`),
    /// so prompts and tools pick the same colors as in Ghostty. Also the
    /// daemon's launch overrides, so terminals it creates without a
    /// per-terminal `env` match. Resolved once per launch.
    let terminalEnvironment: [String: String]
    /// Ghostty resources directory and bundled CLI helper for shell
    /// integration (`GhosttyShellIntegration`). Resolved once per launch.
    var ghosttyResources: String?
    var ghosttyBinary: String?
    /// The saved sidebars the first frame draws (`SidebarSnapshotStore`):
    /// only the real app process sets it; without it nothing is read or
    /// written (tests that build `AppServices`).
    var sidebarSnapshotFile: SidebarSnapshotFile?

    var tag: String? { launch.tag }

    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> AppEnvironment {
        let noActivate = environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
#if DEBUG
        let showcase = environment["CMUX_NEXT_SHOWCASE"] == "1" || ProcessInfo.processInfo.arguments.contains("--showcase")
#else
        let showcase = false
#endif
        let launch = LaunchIdentity.current()
        return AppEnvironment(
            launch: launch,
            noActivate: noActivate,
            showcase: showcase,
            testWindow: TestWindowPlacement.parse(environment, noActivate: noActivate),
            terminalEnvironment: terminalEnvironment(launch: launch, environment: environment),
            ghosttyResources: GhosttyRuntime.resourcesDirectory(environment: environment),
            ghosttyBinary: GhosttyRuntime.cliHelperPath()
        )
    }

    /// The per-terminal `env` provider every local spawn path uses (daemon
    /// connection, new workspaces, the compat CLI): the filtered login
    /// environment, ``terminalEnvironment``, then Ghostty's shell integration
    /// from the config applied at spawn time, so `reload-config` affects
    /// the next terminal.
    func terminalEnvironmentProvider() -> @Sendable () async -> [String: String] {
        let resources = ghosttyResources
        let binary = ghosttyBinary
        return TerminalEnvironment.instance.shared(overrides: terminalEnvironment, integration: {
            await MainActor.run {
                Self.shellIntegration(GhosttyRuntime.shared.shellIntegrationSettings, resources: resources, binary: binary)
            }
        })
    }

    /// Maps the config's raw settings; Ghostty's defaults when no config loaded.
    nonisolated static func shellIntegration(_ settings: GhosttyShellIntegrationSettings?, resources: String?,
                                             binary: String?) -> GhosttyShellIntegration {
        guard let settings else { return GhosttyShellIntegration(resourcesDirectory: resources, ghosttyBinary: binary) }
        return GhosttyShellIntegration(
            mode: GhosttyShellIntegration.Mode(rawValue: settings.mode) ?? .detect,
            features: GhosttyShellIntegration.Features(rawValue: settings.features),
            cursorBlink: settings.cursorBlink,
            resourcesDirectory: resources,
            ghosttyBinary: binary
        )
    }

    static func terminalEnvironment(launch: LaunchIdentity, environment: [String: String]) -> [String: String] {
        let ghostty = TerminalEnvironment.instance.ghostty(
            resourcesDirectory: GhosttyRuntime.resourcesDirectory(environment: environment),
            version: GhosttyRuntime.version
        )
        return ghostty.merging(launch.terminalEnvironment) { _, identity in identity }
    }
}
