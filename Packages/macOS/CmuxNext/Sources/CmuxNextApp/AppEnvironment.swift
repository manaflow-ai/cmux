import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextHomeEngine
import CmuxNextLaunch
import CmuxNextTerminal
import CmuxNextWakeups
import CmuxNextWebUpdates
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
    /// The launch caches' crash-streak decision (p08-startup-089), made on the files lane by the first launch cache
    /// read or the run marker's launch read (`AppRunMarker.launchSafeMode`); nil reads every cache (tests).
    var launchCaches: LaunchSafeMode.Gate?
    /// Reads a launch cache's files on its lane; reads none in a crash streak's safe launch (``launchCaches``).
    var launchCacheReader: LaunchFileReader {
        guard let gate = launchCaches else { return LaunchFileReader() }
        return LaunchFileReader().gated { gate.safeMode.readsLaunchCaches }
    }
    /// What every local terminal of this app gets on top of its filtered
    /// login environment: the launch identity (`LaunchIdentity`) and the
    /// terminal identity Ghostty gives its shells (`TerminalEnvironment.instance.ghostty`),
    /// so prompts and tools pick the same colors as in Ghostty. Also the
    /// daemon's launch overrides, so terminals it creates without a
    /// per-terminal `env` match. Made with no disk call: the keys that need
    /// one (`TERM`, `GHOSTTY_RESOURCES_DIR`) come from ``ghosttyProbe``.
    let terminalEnvironment: [String: String]
    /// The launch's Ghostty lookups (``GhosttyLaunchProbe``: resources, CLI helper,
    /// terminfo), on a launch lane, never on the main thread; each shell's env and the
    /// daemon's `server ensure` await it. Only the real app process starts it; nil
    /// gives shells xterm-256color and no Ghostty folder or helper (tests that build `AppServices`).
    var ghosttyProbe: LaunchRead<GhosttyLaunchProbe>?
    /// Whether this app resolves Ghostty's shell integration for its local
    /// terminals (the daemon connection then echoes
    /// `terminal-frontend-shell-integration-v1`): when it runs from its app
    /// bundle, whose build phase bundles the integration scripts with the
    /// resources (``GhosttyRuntime/bundledResourcesDirectory(bundleURL:resourceURL:)``,
    /// a path, no disk call); otherwise the daemon keeps its own.
    let resolvesShellIntegration: Bool
    /// The saved sidebars the first frame draws (`SidebarSnapshotStore`):
    /// only the real app process sets it; without it nothing is read or
    /// written (tests that build `AppServices`).
    var sidebarSnapshotFile: SidebarSnapshotFile?
    /// That file's launch read, started in `main` before the settings read in one sequence, so it has ended when
    /// `AppServices` is made; nil makes `AppServices` start its own.
    var sidebarSnapshot: LaunchRead<SidebarSnapshotDocument>?
    /// The run marker's launch read (`AppRunMarker.startLaunchRead`), started in `main` with ``marksRun``, before the
    /// settings read in one sequence; nil leaves no marker (tests that build `AppServices`).
    var runMarker: LaunchRead<AppRunMarker.Launch>?
    /// The incognito workspaces the last run left (`IncognitoWorkspaceLedger`), read on a launch lane from
    /// `main`: the launch window's check never reads the file on the main thread. Only the real app process
    /// starts it; without it the ledger starts its own as `AppServices` is built (tests that build `AppServices`).
    var incognitoLeftovers: LaunchRead<IncognitoWorkspaceLedger.Leftovers>?
    /// The browser pages' pictures from the last quit (`BrowserLaunchPictures`), read on a launch lane from `main`.
    /// Only the real app process makes it; without it no picture is read or written (tests that build `AppServices`).
    var browserLaunchPictures: BrowserLaunchPictures?
    /// One picture per window from the last quit (`WindowPictureStore`, feature `savedWindowPicture`). Only the real
    /// app process makes it; without it no window picture is written (tests that build `AppServices`).
    var windowPictures: WindowPictureStore?
    /// The kept web update (`WebUpdates`, NIGHTLY): its state and verified tree, read on a launch lane from `main`.
    /// Nil where the bundle takes no web updates and in tests that build `AppServices`.
    var webUpdates: LaunchRead<WebUpdates.Launch?>?
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The launch's main-job census (`CMUX_NEXT_MAIN_JOB_CENSUS=1`, p08-startup-080): `debug.startup.main_jobs` reads it.
    /// Only the real app process arms it.
    var mainJobCensus: MainJobCensus?
    /// The launch's global-job census (`CMUX_NEXT_GLOBAL_JOB_CENSUS=1`, p08-startup-082): `debug.startup.global_jobs`
    /// reads it. Only the real app process arms it.
    var globalJobCensus: GlobalJobCensus?
    #endif
    /// The Labs page's local feature choices and their file (``FeatureLocalOverrides``), read on a launch lane from
    /// `main` before the settings read, so `AppServices` resolves its features with them. DEV and NIGHTLY only; nil in
    /// Release and in tests that build `AppServices`.
    var featureLocalOverridesFile: URL?
    /// The launch's daemon features for every hello to the local daemon and their last answer (`features.list`),
    /// made in `main` once the features resolve (p12-perf-process-150). Nil in tests that build `AppServices`.
    var daemonFeatureHello: DaemonFeatureHello?
    var featureLocalOverrides: LaunchRead<FeatureLocalOverrides>?
    /// The Debug tunables features replace (``Feature/replaces``), as the build's debug-tunables.json holds them,
    /// read on a launch lane from `main` beside ``featureLocalOverrides``: their features' local overrides
    /// (``FeatureLaunchLocalOverrides``). Only where launch activates the tunable store
    /// (``DebugSettingsService/launchFile(launch:environment:)``); nil in Release and in tests that build `AppServices`.
    var featureTunableOverrides: LaunchRead<[String: Bool]>?
    /// This Mac's layout templates (`LayoutTemplateRepository`): only the real app process sets
    /// it; without it templates live in memory only (tests that build `AppServices`).
    var layoutTemplatesFile: URL?
    /// The acpmux this app starts (``AcpmuxEnvironment/resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)``),
    /// resolved once on the system lane from `main`: its trust check reads this app's signature and hashes the
    /// binary, so the main thread never makes it. The value is nil while it runs (``QuitAgents/environment(_:)``).
    /// Only the real app process starts it; tests that build `AppServices` have none (no acpmux).
    var appAcpmux: LaunchRead<AcpmuxEnvironment?>?
    /// The folder of the Home caches (drafts, scroll anchors, sends, attachment blobs, the Home
    /// list's launch state): only the real app process sets it (the user's Caches folder); without
    /// it each `HomeService` uses a temporary folder of its own (tests that build `AppServices`), so
    /// no test reads a draft another test typed in the same conversation.
    var homeCachesDirectory: URL?
    /// The Home list's caches (its conversations and its last list) of this build's Chief owner, read on a launch
    /// lane from `main` (p08-startup-076): the Home list's first frame never reads them on the main thread. Only the
    /// real app process starts it; without it `HomeService` starts its own as it is made (tests that build `AppServices`).
    var homeListRead: HomeListLaunchRead?
    /// This Mac's install id, read on a launch lane from `main` before the settings read (p08-startup-076). Only the
    /// real app process starts it; without it `CloudService` reads the id at its first use (tests that build `AppServices`).
    var cloudDeviceID: CloudDeviceIDSource?
    /// `CMUX_NEXT_ORACLE_ROOT` and `HOME` of the launch: the oracle case root (its aliases separated by `:`) and the
    /// hermetic home the `terminals` facet rewrites to `$ROOT` and `$HOME` before hashing (schemas/oracle/README.md).
    var oracleRoot: String?
    var launchHome: String?
    /// The action catalog's launch build, which the registry takes: the real app process passes the one
    /// its launch warm-up thread builds (`LaunchWarmup`); tests that build `AppServices` build it on main.
    var actionCatalog = ActionCatalogLaunch()

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

    /// This launch's environment, with no file call (`main` makes it before `NSApplication.run`).
    /// `ghosttyResources` is this app's bundled Ghostty folder by path (nil: not an app bundle).
    static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment, openFiles: OpenFileLimit.Change? = nil,
                        ghosttyResources: String? = GhosttyRuntime.bundledResourcesDirectory()) -> AppEnvironment {
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
            terminalEnvironment: terminalEnvironment(launch: launch, environment: environment)
                .merging(openFiles?.childEnvironment ?? [:]) { $1 },
            resolvesShellIntegration: ghosttyResources.map { !$0.isEmpty } ?? false,
            oracleRoot: environment["CMUX_NEXT_ORACLE_ROOT"],
            launchHome: environment["HOME"]
        )
    }

    /// The per-terminal `env` provider every local spawn path uses (daemon
    /// connection, new workspaces, the compat CLI): the filtered login
    /// environment, ``terminalEnvironment`` with ``ghosttyProbe``'s keys over
    /// it, then Ghostty's shell integration from the config applied at spawn
    /// time (`settings`), so `reload-config` affects the next terminal.
    /// `login` is the login environment (nil: `LoginEnvironmentCache`; a test's own).
    func terminalEnvironmentProvider(
        login: (@Sendable () async -> [String: String]?)? = nil,
        settings: @escaping @MainActor @Sendable () -> GhosttyShellIntegrationSettings? = { GhosttyRuntime.shared.shellIntegrationSettings }
    ) -> @Sendable () async -> [String: String] {
        let (overrides, probe) = (terminalEnvironment, ghosttyProbe)
        let cli = Self.bundledCLI(appResources: Bundle.main.resourceURL?.path, resolvesShellIntegration: resolvesShellIntegration)
        return {
            let probed = await probe?.finished()
            let shared = TerminalEnvironment.instance.shared(
                overrides: overrides.merging(probed?.terminalEnvironment ?? [:]) { _, found in found }, login: login,
                integration: { Self.shellIntegration(await settings(), resources: probed?.resources, binary: probed?.binary) }, cli: cli)
            return await shared()
        }
    }

    /// ``ghosttyProbe``'s keys for the daemon's own environment (`DaemonService.prestart`), awaited
    /// off the main thread; nil without a probe.
    func resolvedTerminalEnvironment() -> (@Sendable () async -> [String: String])? {
        guard let probe = ghosttyProbe else { return nil }
        return { await probe.finished().terminalEnvironment }
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
        let ghostty = TerminalEnvironment.instance.ghostty(resourcesDirectory: nil, version: GhosttyRuntime.version)
        var terminal = ghostty.merging(launch.terminalEnvironment) { _, identity in identity }
        // `cmux chief` in this app's terminals opens this app's Chief: its
        // isolation markers are the app's own environment, which terminals
        // do not inherit (schemas/chief-home/vectors.json).
        terminal["CMUX_CHIEF_HOME"] = ChiefHome.resolve(tag: launch.tag, environment: environment).root.path
        return terminal
    }
}
