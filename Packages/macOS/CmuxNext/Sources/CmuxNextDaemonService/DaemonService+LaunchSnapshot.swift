import CmuxNextApps
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
public import CmuxNextControl
public import CmuxNextDaemon
public import CmuxNextTrace
public import CmuxNextWakeups
public import Foundation
import os

// The launch snapshot (`launch-snapshot-v1`, plans/cmux-next/cmux-tui-contract.md):
// the last layout drawn before the first connection, then replaced in place;
// and the first connect begun in `main` with the remembered daemon socket.
extension DaemonService {
    /// Reads this process's Team ID, then begins the local daemon's first connect attempt with it
    /// (`prestart`). `featureHello`: the app's daemon features for every hello. `terminalStreams`: as in
    /// `localConfiguration`.
    /// Blocks on Security and the install key file: the app runs it on its system lane from `main`.
    public nonisolated static func launchStart(work: BackgroundWork, launch: LaunchIdentity, terminalEnvironment: [String: String],
                                               resolvedTerminalEnvironment: (@Sendable () async -> [String: String])?,
                                               terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                               resolvesShellIntegration: Bool, echoesPlacementShift: Bool,
                                               wireStats: DaemonWireStats?, hangWatch: (any HangWatchScoping)?,
                                               featureHello: DaemonFeatureHello? = nil,
                                               terminalStreams: TerminalStreamsDevice? = nil) -> DaemonLaunchStart {
        let team = CodeSigningTeam.current()
        return DaemonLaunchStart(team: team, prestart: prestart(
            work: work, team: team, launch: launch, terminalEnvironment: terminalEnvironment,
            resolvedTerminalEnvironment: resolvedTerminalEnvironment, terminalEnvironmentProvider: terminalEnvironmentProvider,
            resolvesShellIntegration: resolvesShellIntegration, echoesPlacementShift: echoesPlacementShift,
            wireStats: wireStats, hangWatch: hangWatch, featureHello: featureHello, terminalStreams: terminalStreams))
    }

    /// Begins the local daemon's first connect attempt off the main thread,
    /// at the top of `main`, so it overlaps AppKit's start; `start(launch:…
    /// prestart:)` takes it over. Nil when the launcher cannot be made (the
    /// later `start` reports why). `resolvedTerminalEnvironment`: as in `DaemonLauncher.forApp`. `work` is the app's
    /// one ``BackgroundWork`` (the launcher's disk steps). Its connect milestones (`daemon.connect_started`,
    /// `spawned`, `identified`, `snapshot_received`) go to the launch timings, once each, for the connection the
    /// service attaches. `team`: this process's Team ID. The app calls it on its system lane, after the signature
    /// read that gives `team` (it reads the install key file too).
    public nonisolated static func prestart(work: BackgroundWork, team: String?, launch: LaunchIdentity, terminalEnvironment: [String: String],
                                     resolvedTerminalEnvironment: (@Sendable () async -> [String: String])? = nil,
                                     terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                     resolvesShellIntegration: Bool = false,
                                     echoesPlacementShift: Bool = false,
                                     wireStats: DaemonWireStats? = nil,
                                     hangWatch: (any HangWatchScoping)? = nil,
                                     featureHello: DaemonFeatureHello? = nil,
                                     terminalStreams: TerminalStreamsDevice? = nil) -> DaemonPrestart? {
        guard let launcher = try? DaemonLauncher.forApp(work: work, build: launch.build, team: team,
                                                terminalEnvironment: terminalEnvironment,
                                                resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                                daemonEnvironment: firstPartyAppsEnvironment,
                                                webSocketPageOrigins: pageOrigins, wireStats: wireStats) else { return nil }
        return DaemonPrestart(launcher: launcher, configuration: localConfiguration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: resolvesShellIntegration,
            installKey: launcher.configuration.installKey, echoesPlacementShift: echoesPlacementShift,
            hangWatch: hangWatch, featureHello: featureHello, terminalStreams: terminalStreams), marks: launchConnectMarks())
    }

    /// The launch's connect milestones, sent to the launch timings at the time each happened.
    nonisolated static func launchConnectMarks() -> DaemonConnectMarks {
        DaemonConnectMarks { DaemonLaunchTimings.shared.mark($0, at: $1) }
    }

    /// What the local daemon's supervisor needs from this app at launch: the
    /// first-party app packages shipped in the app bundle (its default apps).
    /// Also the page bundle the daemon serves on its loopback listener (`CMUX_TUI_PAGES_DIR`,
    /// cmux-tui spec/transports.md "App listener and page files").
    /// Plus the app's diagnostic launch knobs under the daemon's names (``DaemonDiagnosticKnobs``),
    /// and this app's pid: the leftover owner idle exit keeps the owner while the app runs.
    nonisolated static var firstPartyAppsEnvironment: [String: String] {
        var environment = ["CMUX_APPS_FIRST_PARTY_DIR": AppPlatformResources.firstParty.path]
        environment["CMUX_TUI_OWNER_APP_PID"] = String(ProcessInfo.processInfo.processIdentifier)
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
    /// begun in `main` (`prestart`) and for the connections after it. `featureHello`: the app's daemon features,
    /// sent in every hello (the daemon outlives the app). `terminalStreams`: its views stream
    /// on it, sized as that device; nil: a connection each.
    nonisolated static func localConfiguration(terminalEnvironment: (@Sendable () async -> [String: String])?,
                                               resolvesShellIntegration: Bool, installKey: FrontendInstallKey?,
                                               echoesPlacementShift: Bool, retryWake: RetryWake? = nil,
                                               hangWatch: (any HangWatchScoping)? = nil,
                                               featureHello: DaemonFeatureHello? = nil,
                                               terminalStreams: TerminalStreamsDevice? = nil) -> DaemonConnection.Configuration {
        // sessionEvents: the state resources (closed history, workspace status,
        // tab records) come only through session.events (nxdog50).
        var configuration = DaemonConnection.Configuration(retryWake: retryWake, terminalEnvironment: terminalEnvironment,
                                                           resolvesShellIntegration: resolvesShellIntegration, sessionEvents: true,
                                                           clientHello: ClientHelloIdentity(installKey: installKey, features: featureHello),
                                                           terminalStreams: terminalStreams)
        // A stopped or wedged owner keeps its socket open: only the heartbeat
        // shows it not connected (cx-jniyz.4).
        configuration.localHeartbeat = true
        configuration.echoesPlacementShift = echoesPlacementShift
        configuration.hangWatch = hangWatch
        // The local daemon's diagnostic sites go to this app's hang reports (``DaemonService/diagnosticSites``).
        configuration.reportsDiagnosticSites = true
        return configuration
    }

    /// Records the local daemon's socket for the next launch
    /// (`DaemonSocketMemory`), so it connects without `server status`. The
    /// endpoint read and the defaults write run off main; nothing waits on them.
    func rememberSocket(_ identity: DaemonIdentity, connection: DaemonConnection) {
        guard let session = launchSnapshot.session, identity.session == session else { return }
        // task-owner: one endpoint read and one defaults write per connection; the store run owns the connection
        Task { @concurrent in
            guard let path = await connection.endpoint?.socketPath else { return }
            DaemonSocketMemory().record(path, session: session)
        }
    }

    /// Waits for the first connection (or for startup to give up): an event,
    /// not a retry, so terminals drawn from the snapshot attach at once.
    /// A dropped waiter returns as startup giving up does.
    public func firstConnection() async {
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in
            connectionWaiters.append(waiter)
        }
    }

    /// Runs at the first connection and when startup gives up: the moment the app's daemon features take
    /// their session values (``DaemonFeatureHello/settle()``, the attached connection's answer or none).
    func resumeConnectionWaiters() {
        featureHello?.settle()
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ()) }
    }
}

/// What the app's launch makes on its system lane for the local daemon (`DaemonService.launchStart`):
/// this process's Team ID, read there and never on the main thread, the first connect attempt begun with it,
/// and the read of the daemon's launch snapshot begun from there.
public nonisolated struct DaemonLaunchStart: Sendable {
    /// This process's Team ID (`CodeSigningTeam`); nil for an ad-hoc or unsigned build.
    public let team: String?
    /// The first connect attempt; nil when its launcher could not be made (`DaemonService.start` reports why).
    public let prestart: DaemonPrestart?
    /// The read of the daemon's launch snapshot, begun on the files lane once the launcher named its session
    /// (``reading(_:)``); nil without a launcher, and the start then posts its own read.
    public let launchSnapshot: LaunchSnapshotPrefetch?

    public init(team: String?, prestart: DaemonPrestart?, launchSnapshot: LaunchSnapshotPrefetch? = nil) {
        self.team = team
        self.prestart = prestart
        self.launchSnapshot = launchSnapshot
    }

    /// The session and state directory whose launch snapshot the daemon's start applies; nil without a launcher.
    public var snapshotNames: (session: String, stateDirectory: URL?)? {
        prestart.map { (session: $0.launcher.configuration.session, stateDirectory: $0.launcher.configuration.stateDirectory) }
    }

    /// This start with `launchSnapshot`, the snapshot's read begun for ``snapshotNames``.
    public func reading(_ launchSnapshot: LaunchSnapshotPrefetch) -> DaemonLaunchStart {
        DaemonLaunchStart(team: team, prestart: prestart, launchSnapshot: launchSnapshot)
    }
}
