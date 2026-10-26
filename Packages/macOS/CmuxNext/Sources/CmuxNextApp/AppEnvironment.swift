import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
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
    /// An isolated test or bench launch (`LaunchIsolation.isolated`: no-activate or
    /// `CMUX_NEXT_ISOLATED_LAUNCH=1`): the fixed test window, and nothing claimed from the
    /// account (no CLI pointer, global hot keys, relaunch at login or browser import offer).
    let isolatedLaunch: Bool
    /// DEBUG showcase profile requested by `--showcase` or `CMUX_NEXT_SHOWCASE=1`.
    let showcase: Bool
    /// `CMUX_NEXT_TEST_WINDOW_SCREEN` / `CMUX_NEXT_TEST_WINDOW_FRAME` in an
    /// isolated launch: where windows open for agent screenshots and benches.
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
    /// Ghostty resources directory for shell integration (`GhosttyShellIntegration`):
    /// the one `CmuxNextApp.prepareLaunchEnvironment` resolved before the freeze.
    let ghosttyResources: String?
    /// The bundled Ghostty CLI helper (`GhosttyRuntime.cliHelperPath`), looked up on a
    /// launch lane (`LaunchRead`) and awaited by each shell's env, never on the main
    /// thread. Only the real app process sets it; nil gives shells no helper (tests
    /// that build `AppServices`).
    var ghosttyBinary: LaunchRead<String?>?
    /// Whether this app resolves Ghostty's shell integration for its local
    /// terminals (the daemon connection then echoes
    /// `terminal-frontend-shell-integration-v1`). Only when the resources
    /// hold the integration scripts; otherwise the daemon keeps its own.
    /// Checked once per launch (the daemon prestart needs it in `main`).
    let resolvesShellIntegration: Bool

    nonisolated static func resolvesShellIntegration(resources: String?) -> Bool {
        guard let resources, !resources.isEmpty else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resources + "/shell-integration", isDirectory: &directory)
            && directory.boolValue
    }
    /// The saved sidebars the first frame draws (`SidebarSnapshotStore`):
    /// only the real app process sets it; without it nothing is read or
    /// written (tests that build `AppServices`).
    var sidebarSnapshotFile: SidebarSnapshotFile?
    /// This Mac's layout templates (`LayoutTemplateRepository`): only the real app process sets
    /// it; without it templates live in memory only (tests that build `AppServices`).
    var layoutTemplatesFile: URL?
    /// The folder of the Home caches (drafts, scroll anchors, sends, attachment blobs, the Home
    /// list's launch state): only the real app process sets it (the user's Caches folder); without
    /// it each `HomeService` uses a temporary folder of its own (tests that build `AppServices`), so
    /// no test reads a draft another test typed in the same conversation.
    var homeCachesDirectory: URL?
    /// `CMUX_NEXT_ORACLE_ROOT` and `HOME` of the launch: the oracle case root (its aliases separated by `:`) and the
    /// hermetic home the `terminals` facet rewrites to `$ROOT` and `$HOME` before hashing (schemas/oracle/README.md).
    var oracleRoot: String?
    var launchHome: String?

    var tag: String? { launch.tag }
    /// The build whose state roots this app uses (per-build isolation, cx-is1kf).
    var build: BuildIdentity { Self.build(launch: launch) }

    /// This app's build (`LaunchIdentity.build`: its bundle id and shipped tag),
    /// the same pair its terminals' `cmux` CLI reads from `CMUX_BUNDLE_ID` and `CMUX_TAG`, so both
    /// resolve one set of roots. A Debug compile may run as another bundle id
    /// (`CMUX_NEXT_CHIEF_BUILD_ID`, tests only; also its Chief home, `ChiefHome`).
    nonisolated static func build(launch: LaunchIdentity,
                                  environment: [String: String] = ProcessInfo.processInfo.environment,
                                  isDebugBuild: Bool = isDebugCompile) -> BuildIdentity {
        if isDebugBuild, let other = environment["CMUX_NEXT_CHIEF_BUILD_ID"], !other.isEmpty {
            return BuildIdentity(bundleID: other, bundledTag: nil)
        }
        return launch.build
    }

    nonisolated static var isDebugCompile: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// This launch's environment, its Ghostty resources looked up now (tests that build `AppServices`).
    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment, openFiles: OpenFileLimit.Change? = nil) -> AppEnvironment {
        current(environment, openFiles: openFiles, ghosttyResources: GhosttyRuntime.resourcesDirectory(environment: environment))
    }

    /// This launch's environment on the Ghostty resources `main` already resolved, so they are not looked up again.
    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment, openFiles: OpenFileLimit.Change? = nil,
                        ghosttyResources: String?) -> AppEnvironment {
        let isolation = LaunchIsolation(environment: environment)
#if DEBUG
        let showcase = environment["CMUX_NEXT_SHOWCASE"] == "1" || ProcessInfo.processInfo.arguments.contains("--showcase")
#else
        let showcase = false
#endif
        let launch = LaunchIdentity.current()
        return AppEnvironment(
            launch: launch,
            noActivate: isolation.noActivate,
            isolatedLaunch: isolation.isolated,
            showcase: showcase,
            testWindow: TestWindowPlacement.parse(environment, isolatedLaunch: isolation.isolated),
            terminalEnvironment: terminalEnvironment(launch: launch, environment: environment, ghosttyResources: ghosttyResources)
                .merging(openFiles?.childEnvironment ?? [:]) { $1 },
            ghosttyResources: ghosttyResources,
            resolvesShellIntegration: Self.resolvesShellIntegration(resources: ghosttyResources),
            oracleRoot: environment["CMUX_NEXT_ORACLE_ROOT"],
            launchHome: environment["HOME"]
        )
    }

    /// The per-terminal `env` provider every local spawn path uses (daemon
    /// connection, new workspaces, the compat CLI): the filtered login
    /// environment, ``terminalEnvironment``, then Ghostty's shell integration
    /// from the config applied at spawn time, so `reload-config` affects
    /// the next terminal.
    func terminalEnvironmentProvider() -> @Sendable () async -> [String: String] {
        let resources = ghosttyResources
        let binaryRead = ghosttyBinary
        return TerminalEnvironment.instance.shared(overrides: terminalEnvironment, integration: {
            let binary: String? = await binaryRead?.finished() ?? nil
            return await MainActor.run {
                Self.shellIntegration(GhosttyRuntime.shared.shellIntegrationSettings, resources: resources, binary: binary)
            }
        }, cli: Self.bundledCLI(appResources: Bundle.main.resourceURL?.path, resolvesShellIntegration: resolvesShellIntegration))
    }

    /// The bundled `cmux` for this app's terminals: `<Resources>/bin`, and
    /// the `cmux-cli-path` layers when this app (not the daemon) integrates
    /// the shell, since they wrap the integration the app writes.
    nonisolated static func bundledCLI(appResources: String?, resolvesShellIntegration: Bool) -> BundledCLIEnvironment? {
        guard let appResources, !appResources.isEmpty else { return nil }
        return BundledCLIEnvironment(binDirectory: appResources + "/bin",
                                     pathIntegration: resolvesShellIntegration ? appResources + "/cmux-cli-path" : nil)
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

    static func terminalEnvironment(launch: LaunchIdentity, environment: [String: String], ghosttyResources: String?) -> [String: String] {
        let ghostty = TerminalEnvironment.instance.ghostty(resourcesDirectory: ghosttyResources, version: GhosttyRuntime.version)
        var terminal = ghostty.merging(launch.terminalEnvironment) { _, identity in identity }
        // `cmux chief` in this app's terminals opens this app's Chief: its
        // isolation markers are the app's own environment, which terminals
        // do not inherit (schemas/chief-home/vectors.json).
        terminal["CMUX_CHIEF_HOME"] = ChiefHome.resolve(tag: launch.tag, environment: environment).root.path
        return terminal
    }
}
