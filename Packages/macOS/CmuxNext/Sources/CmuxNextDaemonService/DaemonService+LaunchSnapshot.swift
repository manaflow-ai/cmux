import CmuxNextApps
import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextTrace
public import CmuxNextWakeups
import Foundation
import os

// The launch snapshot (`launch-snapshot-v1`, plans/cmux-next/cmux-tui-contract.md):
// the last layout drawn before the first connection, then replaced in place;
// and the first connect begun in `main` with the remembered daemon socket.
extension DaemonService {
    /// Applies the daemon's launch snapshot as a provisional tree, so the
    /// first frame shows the last layout instead of the connecting state.
    /// The path comes from the last handshake, else from the daemon's state
    /// directory (`stateDirectory`, a tagged build's), so cleared defaults do
    /// not lose the snapshot; a missing, stale or unreadable file shows
    /// nothing. The file is small (the daemon caps it at 8 MiB) and local,
    /// and reading it replaces waiting for the daemon, so it is read before
    /// the first window.
    func showLaunchSnapshot(session: String, stateDirectory: URL?) {
        guard let path = launchSnapshotLocation.path(session: session)
            ?? LaunchSnapshotLocation.find(session: session, in: stateDirectory) else { return }
        let snapshot: LaunchSnapshot
        do { snapshot = try LaunchSnapshot.load(path: path, session: session) } catch {
            logger.error("launch snapshot skipped: \(String(describing: error), privacy: .public)")
            return
        }
        store.applyProvisional(snapshot: snapshot.tree)
        launchSnapshotWindows = snapshot.windows
        Self.launchMark("launch_snapshot_applied")
    }

    /// Records the snapshot path the local daemon reported, for the next launch.
    func rememberLaunchSnapshot(_ identity: DaemonIdentity) {
        guard let session = launchSnapshotSession, identity.session == session else { return }
        launchSnapshotLocation.record(identity.launchSnapshotPath, session: session)
    }

    /// Reads this process's Team ID, then begins the local daemon's first connect attempt with it
    /// (`prestart`).
    /// Blocks on Security and the install key file: the app runs it on its system lane from `main`.
    public nonisolated static func launchStart(work: BackgroundWork, launch: LaunchIdentity, terminalEnvironment: [String: String],
                                               resolvedTerminalEnvironment: (@Sendable () async -> [String: String])?,
                                               terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                               resolvesShellIntegration: Bool, echoesPlacementShift: Bool,
                                               wireStats: DaemonWireStats?, hangWatch: (any HangWatchScoping)?) -> DaemonLaunchStart {
        let team = CodeSigningTeam.current()
        return DaemonLaunchStart(team: team, prestart: prestart(
            work: work, team: team, launch: launch, terminalEnvironment: terminalEnvironment,
            resolvedTerminalEnvironment: resolvedTerminalEnvironment, terminalEnvironmentProvider: terminalEnvironmentProvider,
            resolvesShellIntegration: resolvesShellIntegration, echoesPlacementShift: echoesPlacementShift,
            wireStats: wireStats, hangWatch: hangWatch))
    }

    /// Begins the local daemon's first connect attempt off the main thread,
    /// at the top of `main`, so it overlaps AppKit's start; `start(launch:…
    /// prestart:)` takes it over. Nil when the launcher cannot be made (the
    /// later `start` reports why). `resolvedTerminalEnvironment`: as in `DaemonLauncher.forApp`. `work` is the app's
    /// one ``BackgroundWork`` (the launcher's disk steps). `team`: this process's Team ID. The app calls it on
    /// its system lane, after the signature read that gives `team` (it reads the install key file too).
    public nonisolated static func prestart(work: BackgroundWork, team: String?, launch: LaunchIdentity, terminalEnvironment: [String: String],
                                     resolvedTerminalEnvironment: (@Sendable () async -> [String: String])? = nil,
                                     terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                     resolvesShellIntegration: Bool = false,
                                     echoesPlacementShift: Bool = false,
                                     wireStats: DaemonWireStats? = nil,
                                     hangWatch: (any HangWatchScoping)? = nil) -> DaemonPrestart? {
        guard let launcher = try? DaemonLauncher.forApp(work: work, build: launch.build, team: team,
                                                terminalEnvironment: terminalEnvironment,
                                                resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                                daemonEnvironment: firstPartyAppsEnvironment,
                                                webSocketPageOrigins: pageOrigins, wireStats: wireStats) else { return nil }
        return DaemonPrestart(launcher: launcher, configuration: localConfiguration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: resolvesShellIntegration,
            installKey: launcher.configuration.installKey, echoesPlacementShift: echoesPlacementShift,
            hangWatch: hangWatch))
    }

    /// What the local daemon's supervisor needs from this app at launch: the
    /// first-party app packages shipped in the app bundle (its default apps).
    /// Also the page bundle the daemon serves on its loopback listener (`CMUX_TUI_PAGES_DIR`,
    /// cmux-tui spec/transports.md "App listener and page files").
    /// Plus the app's diagnostic launch knobs under the daemon's names (``DaemonDiagnosticKnobs``).
    nonisolated static var firstPartyAppsEnvironment: [String: String] {
        var environment = ["CMUX_APPS_FIRST_PARTY_DIR": AppPlatformResources.firstParty.path]
        if let pages = pageBundleDirectory { environment["CMUX_TUI_PAGES_DIR"] = pages.path }
        environment.merge(DaemonDiagnosticKnobs(processEnvironment: ProcessInfo.processInfo.environment).daemonEnvironment) { own, _ in own }
        return environment
    }

    /// The page origins the daemon's loopback listener admits: every first-party page of the app
    /// (`cmux-page://cmux.home-channels`, `cmux-page://cmux.history`, ...; cx-hnmbt.2, cx-hnmbt.10),
    /// so each can open its own daemon WebSocket and gets its page id from its Origin. No other
    /// origin.
    nonisolated static var pageOrigins: [String] { FirstPartyPages.origins }
    /// The origin an owner without `ws-listen-origins-v1` gets on `ws-listen`: the Channels page,
    /// the app's one WebSocket client before cx-hnmbt.10.
    nonisolated static let channelsPageOrigin = "cmux-page://cmux.home-channels"

    /// `pages/` of the CmuxNextPages resource bundle inside this app (built by
    /// build-pages-web.sh), nil when it is not there (tests, a bare binary).
    nonisolated static var pageBundleDirectory: URL? {
        guard let resources = Bundle.main.resourceURL,
              let bundle = Bundle(url: resources.appending(path: "CmuxNext_CmuxNextPages.bundle")),
              let pages = bundle.resourceURL?.appending(path: "pages", directoryHint: .isDirectory),
              FileManager.default.fileExists(atPath: pages.appending(path: "home-channels/index.html").path)
        else { return nil }
        return pages
    }

    /// The local daemon's connection configuration, for the first connect
    /// begun in `main` (`prestart`) and for the connections after it.
    nonisolated static func localConfiguration(terminalEnvironment: (@Sendable () async -> [String: String])?,
                                               resolvesShellIntegration: Bool, installKey: FrontendInstallKey?,
                                               echoesPlacementShift: Bool, retryWake: RetryWake? = nil,
                                               hangWatch: (any HangWatchScoping)? = nil) -> DaemonConnection.Configuration {
        // sessionEvents: the state resources (closed history, workspace status,
        // tab records) come only through session.events (nxdog50).
        var configuration = DaemonConnection.Configuration(retryWake: retryWake, terminalEnvironment: terminalEnvironment,
                                                           resolvesShellIntegration: resolvesShellIntegration, sessionEvents: true,
                                                           clientHello: ClientHelloIdentity(installKey: installKey))
        // A stopped or wedged owner keeps its socket open: only the heartbeat
        // shows it not connected (cx-jniyz.4).
        configuration.localHeartbeat = true
        configuration.echoesPlacementShift = echoesPlacementShift
        configuration.hangWatch = hangWatch
        return configuration
    }

    /// Records the local daemon's socket for the next launch
    /// (`DaemonSocketMemory`), so it connects without `server status`.
    func rememberSocket(_ identity: DaemonIdentity, connection: DaemonConnection) async {
        guard let session = launchSnapshotSession, identity.session == session,
              let path = await connection.endpoint?.socketPath else { return }
        DaemonSocketMemory().record(path, session: session)
    }

    /// Waits for the first connection (or for startup to give up): an event,
    /// not a retry, so terminals drawn from the snapshot attach at once.
    public func firstConnection() async {
        await withCheckedContinuation { connectionWaiters.append($0) }
    }

    func resumeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// What the app's launch makes on its system lane for the local daemon (`DaemonService.launchStart`):
/// this process's Team ID, read there and never on the main thread, and the first connect attempt begun with it.
public nonisolated struct DaemonLaunchStart: Sendable {
    /// This process's Team ID (`CodeSigningTeam`); nil for an ad-hoc or unsigned build.
    public let team: String?
    /// The first connect attempt; nil when its launcher could not be made (`DaemonService.start` reports why).
    public let prestart: DaemonPrestart?

    public init(team: String?, prestart: DaemonPrestart?) {
        self.team = team
        self.prestart = prestart
    }
}
