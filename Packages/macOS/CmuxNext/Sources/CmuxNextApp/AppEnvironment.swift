import CmuxNextCompat
import CmuxNextControl
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextTerminal
import CmuxNextUpdater
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
    /// DEBUG-only auth capture fixture. This composes isolated, offline auth
    /// dependencies for fleet captures; it is never enabled in release builds.
    let authCaptureFixture: Bool
    /// A PR capture slot's neutral shell home (``captureShellHome(_:)``): this run is under capture, so its
    /// terminals start their shells with that folder's rc files and its panes name the showcase Mac.
    var captureShellHome: String?
    /// Whether this run names the showcase Mac instead of this host (`AgentTabStore.localMachineName`):
    /// a showcase run, or a run under capture.
    var namesShowcaseMac: Bool { showcase || captureShellHome != nil }
    /// `CMUX_NEXT_TEST_WINDOW_SCREEN` / `CMUX_NEXT_TEST_WINDOW_FRAME` with
    /// no-activate: where windows open for agent screenshots.
    let testWindow: TestWindowPlacement?
    /// Mark this run for crash recovery (`AppRunMarker`): only the real app
    /// process, never tests that build `AppServices`.
    var marksRun = false
    /// This launch is the relaunch into an update nobody clicked, in an app the user was not in
    /// (`UpdateRelaunchFocus`): it starts behind the user's app (`InputVerificationService.startNoActivateGuard`). Only the
    /// real app process reads it.
    var relaunchBehind: UpdateRelaunchFocus?
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
    /// Whether this app resolves Ghostty's shell integration for its local
    /// terminals (the daemon connection then echoes
    /// `terminal-frontend-shell-integration-v1`). Only when the resources
    /// hold the integration scripts; otherwise the daemon keeps its own.
    var resolvesShellIntegration: Bool { Self.resolvesShellIntegration(resources: ghosttyResources) }

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

    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment, openFiles: OpenFileLimit.Change? = nil) -> AppEnvironment {
        let noActivate = environment["CMUX_NEXT_NO_ACTIVATE"] == "1"
#if DEBUG
        let showcase = environment["CMUX_NEXT_SHOWCASE"] == "1" || ProcessInfo.processInfo.arguments.contains("--showcase")
        let authCaptureFixture = environment["CMUX_NEXT_AUTH_CAPTURE_FIXTURE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("--auth-capture-fixture")
#else
        let showcase = false
        let authCaptureFixture = false
#endif
        let launch = LaunchIdentity.current()
        return AppEnvironment(
            launch: launch,
            noActivate: noActivate,
            showcase: showcase,
            authCaptureFixture: authCaptureFixture,
            captureShellHome: captureShellHome(environment),
            testWindow: TestWindowPlacement.parse(environment, noActivate: noActivate),
            terminalEnvironment: terminalEnvironment(launch: launch, environment: environment).merging(openFiles?.childEnvironment ?? [:]) { $1 },
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

    static func terminalEnvironment(launch: LaunchIdentity, environment: [String: String]) -> [String: String] {
        let ghostty = TerminalEnvironment.instance.ghostty(
            resourcesDirectory: GhosttyRuntime.resourcesDirectory(environment: environment),
            version: GhosttyRuntime.version
        )
        var terminal = ghostty.merging(launch.terminalEnvironment) { _, identity in identity }
        // `cmux chief` in this app's terminals opens this app's Chief: its
        // isolation markers are the app's own environment, which terminals
        // do not inherit (schemas/chief-home/vectors.json).
        terminal["CMUX_CHIEF_HOME"] = ChiefHome.resolve(tag: launch.tag, environment: environment).root.path
        // Under capture, zsh reads the slot's neutral rc files (a `$ ` prompt), never the account's
        // (`%n@%m`: the capture host's name, which the capture's privacy check refuses). Ghostty's and the
        // bundled CLI's ZDOTDIR layers wrap it and hand it back before `.zshrc` runs. The terminals run zsh
        // there: bash and fish read the account's `HOME`, which LaunchServices keeps, so they would not see them.
        if let shellHome = captureShellHome(environment) {
            terminal["ZDOTDIR"] = shellHome
            terminal["SHELL"] = "/bin/zsh"
        }
        return terminal
    }

    /// `CMUX_CAPTURE_SHELL_HOME`: the folder a PR capture slot (cmuxterm-hq capture-host) writes neutral shell
    /// startup files into and names in the clone's `LSEnvironment`, or that a DEBUG launch passes in its environment
    /// (the media tours; `LaunchIdentity.inheritedKeys` keeps it). Nil unless it is an absolute path to a folder.
    /// The check itself is `MacName.captureShellHome`, which this Mac's names under capture read too.
    nonisolated static func captureShellHome(_ environment: [String: String],
                                             isFolder: (String) -> Bool = MacName.existingFolder) -> String? {
        MacName.captureShellHome(environment, isFolder: isFolder)
    }
}
