import CmuxNextApps
import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
    /// Begins the local daemon's first connect attempt off the main thread,
    /// at the top of `main`, so it overlaps AppKit's start; `start(launch:…
    /// prestart:)` takes it over. Nil when the launcher cannot be made (the
    /// later `start` reports why). `resolvedTerminalEnvironment`: as in `DaemonLauncher.forApp`. `work` is the app's
    /// one ``BackgroundWork`` (the launcher's disk steps). Its connect milestones (`daemon.connect_started`,
    /// `spawned`, `identified`, `snapshot_received`) go to the launch timings, once each, for the connection the
    /// service attaches.
    public nonisolated static func prestart(work: BackgroundWork, launch: LaunchIdentity, terminalEnvironment: [String: String],
                                     resolvedTerminalEnvironment: (@Sendable () async -> [String: String])? = nil,
                                     terminalEnvironmentProvider: @escaping @Sendable () async -> [String: String],
                                     resolvesShellIntegration: Bool = false,
                                     echoesPlacementShift: Bool = false,
                                     wireStats: DaemonWireStats? = nil,
                                     hangWatch: (any HangWatchScoping)? = nil) -> DaemonPrestart? {
        guard let launcher = try? DaemonLauncher.forApp(work: work, build: launch.build,
                                                terminalEnvironment: terminalEnvironment,
                                                resolvedTerminalEnvironment: resolvedTerminalEnvironment,
                                                daemonEnvironment: firstPartyAppsEnvironment,
                                                webSocketPageOrigins: pageOrigins, wireStats: wireStats) else { return nil }
        return DaemonPrestart(launcher: launcher, configuration: localConfiguration(
            terminalEnvironment: terminalEnvironmentProvider, resolvesShellIntegration: resolvesShellIntegration,
            installKey: launcher.configuration.installKey, echoesPlacementShift: echoesPlacementShift,
            hangWatch: hangWatch), marks: launchConnectMarks())
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
        guard let session = launchSnapshot.session, identity.session == session,
              let path = await connection.endpoint?.socketPath else { return }
        DaemonSocketMemory().record(path, session: session)
    }

    /// Waits for the first connection (or for startup to give up): an event,
    /// not a retry, so terminals drawn from the snapshot attach at once.
    /// A dropped waiter returns as startup giving up does.
    public func firstConnection() async {
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in
            connectionWaiters.append(waiter)
        }
    }

    func resumeConnectionWaiters() {
        let waiters = connectionWaiters
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ()) }
    }
}
