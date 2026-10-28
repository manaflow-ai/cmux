import CmuxNextApps
import CmuxNextCompat
public import CmuxNextControl
public import CmuxNextDaemon
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

    /// Begins the local daemon's first connect attempt off the main thread,
    /// at the top of `main`, so it overlaps AppKit's start; `start(launch:…
    /// prestart:)` takes it over. Nil when the launcher cannot be made (the
    /// later `start` reports why).
    public nonisolated static func prestart(launch: LaunchIdentity, terminalEnvironment: [String: String],
                                     terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                     resolvesShellIntegration: Bool = false,
                                     echoesPlacementShift: Bool = false) -> DaemonPrestart? {
        guard let launcher = try? DaemonLauncher.forApp(build: launch.build,
                                                terminalEnvironment: terminalEnvironment,
                                                daemonEnvironment: firstPartyAppsEnvironment,
                                                webSocketPageOrigins: pageOrigins) else { return nil }
        return DaemonPrestart(launcher: launcher, configuration: localConfiguration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: resolvesShellIntegration,
            installKey: launcher.configuration.installKey, echoesPlacementShift: echoesPlacementShift))
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
                                               echoesPlacementShift: Bool, retryWake: RetryWake? = nil) -> DaemonConnection.Configuration {
        // sessionEvents: the state resources (closed history, workspace status,
        // tab records) come only through session.events (nxdog50).
        var configuration = DaemonConnection.Configuration(retryWake: retryWake, terminalEnvironment: terminalEnvironment,
                                                           resolvesShellIntegration: resolvesShellIntegration, sessionEvents: true,
                                                           clientHello: ClientHelloIdentity(installKey: installKey))
        // A stopped or wedged owner keeps its socket open: only the heartbeat
        // shows it not connected (cx-jniyz.4).
        configuration.localHeartbeat = true
        configuration.echoesPlacementShift = echoesPlacementShift
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
