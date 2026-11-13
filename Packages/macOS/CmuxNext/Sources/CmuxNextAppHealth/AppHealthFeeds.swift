public import AppKit
import CmuxNextCompat
public import CmuxNextControl
import CmuxNextDaemon
public import CmuxNextDaemonService
public import CmuxNextPages
public import CmuxNextWakeups
import Darwin
public import Foundation

/// App health's feeds (the shared health contract; Leo, 2026-11-09: "displaying a tiny situation
/// somewhere in the app that lets the user know... or better yet, figure out how to auto repair that
/// kinda thing"): each owner tells ``AppHealth`` what it sees, with no decision of its own, and
/// takes back the repair the Rust model asks for. Made and started once by the App (AppServices), before the daemon starts.
///
/// - pages and their Chromium renderers: `AppHealthPageFeed`;
/// - the session daemon (`sessionDaemon`): each `server ensure` of the launcher
///   (`DaemonHealthSink`) and, once, the size of its registry on disk. Its only
///   "repair" is `holdReplace`, which ``AppHealth/holdsReplace`` exposes to the launcher's replace path;
/// - the session daemon connection (`acpmux`, "Connection to the session service"): connected or not,
///   answering its heartbeat and its requests or not (`DaemonHealthSink`: the first
///   timed-out request shows it at once). Repairs: Retry Now, then a reconnect with a fresh drop budget;
///   never a kill;
/// - the page host (`pageHost`): page loads and the daemon's page listener (asked for when a page
///   found no listener credential). Repair: `DaemonService.ensurePageListener()`.
@MainActor
public final class AppHealthFeeds {
    /// The app's health (the Rust model's host), which every feed writes to.
    public let health: AppHealth
    /// App health's popover; a trigger (the restore lane's sidebar card) calls `popover.open(over:)`.
    public let popover: AppHealthPopover
    private let daemon: DaemonService
    private let stateDirectory: URL?
    private let work: BackgroundWork
    /// App health's page and renderer feed; the App hands it to the page host every page view is made with.
    public let pageFeed: any PageHealthFeed
    /// The follow of the local daemon connection (`AppHealthConnectionFeed`), for the app's life.
    private var connectionFeed: Task<Void, Never>?
    /// Each window's footer line (``makeIndicator(over:)``) and the headline they show.
    private let indicators = NSHashTable<AppHealthIndicatorView>.weakObjects()
    private var headline: AppHealth.Headline?

    /// - Parameters:
    ///   - stateDirectory: The session daemon's state directory, whose registry size is read once.
    ///   - work: The app's blocking-work lanes (the size read runs on `.files`).
    ///   - overlayProcess: The overlay pages' one web content process, for the popover's panel.
    public init(daemon: DaemonService, stateDirectory: URL?, work: BackgroundWork, overlayProcess: PageOverlayProcess?) {
        let health = AppHealth()
        self.health = health
        self.daemon = daemon
        self.stateDirectory = stateDirectory
        self.work = work
        pageFeed = AppHealthPageFeed(health: health)
        popover = AppHealthPopover(health: health, overlayProcess: overlayProcess)
    }

    /// Before the daemon starts (its first ensure is a health fact). The debug socket's `debug.health`
    /// ops attach when the control socket starts (`ControlRouter.attach(health:)`). Runs once.
    public func start() {
        guard connectionFeed == nil else { return }
        let health = health
        // The footer lines follow the snapshot, in order, on main (one subscription for the app's life, as this object's).
        health.subscribe { [self] snapshot in
            let headline = AppHealth.headline(of: snapshot)
            MainDelivery().later { self.show(headline) } // always queued, so the lines keep the snapshots' order
        }
        // A restore that still makes progress holds the watch's automatic replace.
        daemon.recovery.holdsReplace = { health.holdsReplace }
        // The session daemon: the launcher's facts, and once the registry's size.
        health.register(AppHealth.sessionDaemonID, kind: .sessionDaemon, label: AppHealthStrings.sessionDaemon)
        if let stateDirectory {
            work.post(.bestEffort, mayBlock: .files) {
                health.size(AppHealth.sessionDaemonID, bytes: AppHealthRegistrySize.bytes(in: stateDirectory))
            }
        }

        // The connection: timed only once it was up (a launch that is still restoring is the
        // session daemon's slow state, not a lost connection).
        health.register(AppHealth.acpmuxID, kind: .acpmux, label: AppHealthStrings.connection, visible: false)
        let daemon = daemon
        health.setRepair(.acpmux) { [weak daemon] action in await Self.repairConnection(daemon, action.action) }
        connectionFeed = AppHealthConnectionFeed.follow(daemon, health: health)

        // The page host.
        health.register(AppHealth.pageHostID, kind: .pageHost, label: AppHealthStrings.pageHost)
        // The service's facts (its launcher's ensures, its requests, its page listener). A request that
        // timed out says "not answering" at once (no wait for the heartbeat's misses).
        daemon.health.bind { [health] signal in Self.note(signal, health: health) }
        health.setRepair(.pageHost) { [weak daemon] _ in await Self.restartPageHost(daemon) }

        #if DEBUG
        let stopped = AppHealthStoppedOwner()
        health.setInjector(.sessionDaemon) { [weak daemon] _, fault in await stopped.inject(fault, daemon: daemon) }
        health.setInjector(.acpmux) { [weak daemon] _, fault in await Self.dropConnection(daemon, fault: fault) }
        health.setInjector(.pageHost) { [weak daemon] _, fault in await Self.removeListenerFile(daemon, fault: fault) }
        #endif
    }

    /// A window's footer line: hidden while all is well, a press opens the popover over `window`.
    public func makeIndicator(over window: @escaping @MainActor () -> NSWindow?) -> AppHealthIndicatorView {
        let view = AppHealthIndicatorView()
        view.onPress = { [popover] in popover.open(over: window()) }
        view.show(headline)
        indicators.add(view)
        return view
    }

    private func show(_ headline: AppHealth.Headline?) {
        guard headline != self.headline else { return }
        self.headline = headline
        for view in indicators.allObjects { view.show(headline) }
    }

    nonisolated static func note(_ signal: DaemonHealthSink.Signal, health: AppHealth) {
        switch signal {
        case .started: health.noteDaemonStarted()
        case .ready(let pid): health.noteDaemonReady(pid: pid)
        case .exited: health.noteDaemonExited()
        case .restoring: health.noteDaemonRestoring(pid: nil)
        case .requestTimedOut:
            health.visibility(AppHealth.acpmuxID, visible: true)
            health.event(AppHealth.acpmuxID, .disconnected)
        case .requestAnswered:
            health.event(AppHealth.acpmuxID, .connected)
            health.visibility(AppHealth.acpmuxID, visible: false)
        case .pageListenerMissing: health.event(AppHealth.pageHostID, .listenerMissing)
        case .pageListenerReady: health.event(AppHealth.pageHostID, .loaded)
        }
    }

    static func repairConnection(_ daemon: DaemonService?, _ action: AppHealth.Repair) async -> Bool {
        guard let daemon else { return false }
        switch action {
        case .reconnect: daemon.recovery.retryNow()
        case .restartConnection:
            // A connected daemon that stopped answering keeps its socket through a wake: drop it, so
            // the connection's own reconnect opens a fresh one (the daemon process is never touched).
            if let connection = daemon.connection { await connection.dropTransport() }
            daemon.reconnectNow()
        default: return false
        }
        return true
    }

    static func restartPageHost(_ daemon: DaemonService?) async -> Bool {
        guard let daemon, let outcome = try? await daemon.ensurePageListener() else { return false }
        return outcome != .unsupported
    }

    #if DEBUG
    /// Debug: drops the daemon connection for real; the service's own reconnect follows.
    static func dropConnection(_ daemon: DaemonService?, fault: String) async -> Bool {
        guard fault == "hang", let daemon, let connection = daemon.connection else { return false }
        await connection.dropTransport()
        daemon.reconnectNow()
        return true
    }

    /// Debug: deletes the daemon's page listener credential file (`<socket>.websocket.json`).
    static func removeListenerFile(_ daemon: DaemonService?, fault: String) async -> Bool {
        guard fault == "hang", let daemon, let endpoint = try? await daemon.endpoint() else { return false }
        let path = endpoint.socketPath + ".websocket.json"
        // task-owner: one file delete off the main actor; ends with it.
        return await Task.detached(priority: .utility) { (try? FileManager.checked.removeItem(atPath: path)) != nil }.value
    }
    #endif
}

/// The session daemon connection as app health's `acpmux` part. A healthy connection is not timed
/// (the model's silence rule needs beats more often than the 15 s heartbeat asks); a lost or
/// unanswering one is shown and marked `disconnected`, and the ladder repairs it.
@MainActor
enum AppHealthConnectionFeed {
    enum Link: Equatable, Sendable {
        case starting, up, down
    }

    static func follow(_ daemon: DaemonService, health: AppHealth) -> Task<Void, Never> {
        let links = ObservationStream { [weak daemon] () -> Link in
            guard let daemon else { return .starting }
            if case .connected = daemon.store.connectionState { return daemon.recovery.daemonNotAnswering ? .down : .up }
            // Before the first connection of this launch the daemon is still starting.
            return daemon.store.connects > 0 ? .down : .starting
        }
        // task-owner: AppHealthFeeds (`connectionFeed`), for the app's life; event driven (Observation).
        return Task {
            for await link in links {
                switch link {
                case .starting:
                    break
                case .up:
                    health.event(AppHealth.acpmuxID, .connected)
                    health.visibility(AppHealth.acpmuxID, visible: false)
                case .down:
                    health.visibility(AppHealth.acpmuxID, visible: true)
                    health.event(AppHealth.acpmuxID, .disconnected)
                }
            }
        }
    }
}

/// The session daemon's data on disk: `workspace-registry.sqlite3`, its WAL and an output cleanup's
/// staging copy, in the state directory and its session folders (one level down).
nonisolated struct AppHealthRegistrySize {
    static let names = ["workspace-registry.sqlite3", "workspace-registry.sqlite3-wal", "workspace-registry.sqlite3.output-cleanup"]

    /// Blocking file reads: call on a `.files` lane.
    static func bytes(in directory: URL) -> UInt64 {
        let files = FileManager.checked
        let folders = [directory] + ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.blockingResourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        var total: UInt64 = 0
        for folder in folders {
            for name in names {
                let path = folder.appendingPathComponent(name).path
                if let size = (try? files.attributesOfItem(atPath: path))?[.size] as? NSNumber { total += size.uint64Value }
            }
        }
        return total
    }
}

#if DEBUG
/// Debug: the owner `debug.health.inject {id: "sessionDaemon", fault: "hang"}` stopped (SIGSTOP),
/// continued by `fault: "resume"`.
@MainActor
final class AppHealthStoppedOwner {
    private var pid: Int32?

    func inject(_ fault: String, daemon: DaemonService?) -> Bool {
        switch fault {
        case "hang":
            guard let owner = daemon?.store.identity?.pid, owner > 0, Darwin.kill(owner, SIGSTOP) == 0 else { return false }
            pid = owner
            return true
        case "resume":
            guard let stopped = pid else { return false }
            pid = nil
            return Darwin.kill(stopped, SIGCONT) == 0
        default:
            return false
        }
    }
}
#endif
