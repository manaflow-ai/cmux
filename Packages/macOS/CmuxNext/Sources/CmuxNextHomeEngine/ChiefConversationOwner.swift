import CmuxNextAgentPane
public import CmuxNextDaemon
public import Foundation
public import Observation
import os

/// The owner of Home's conversations: the cmux-tui daemon session of the
/// Chief home (`ChiefHome.session`, state in `ChiefHome.daemonStateDirectory`),
/// this build's own (one Chief per build; plans/cmux-next/home-state-ownership.md).
/// It is the single writer of the Chief conversation; the OptChat log is
/// written only by the one brain host of the same home, which catches up
/// from this owner after any stop, so the visible chat and the Chief's memory
/// stay one history across launches of this build.
///
/// A build's own daemon (its tag's session) still owns its workspaces,
/// terminals and the Home workspace's tabs; a conversation tab there points
/// at a conversation of this owner by id.
///
/// The owner process is detached and outlives the app; the next launch
/// ensures it and attaches. It is never handed off to the connecting
/// binary only for being another build (an older build that still shares
/// NIGHTLY's home would restart it in turn). One whose executable an update
/// deleted is no live build's own: it is handed off to this build once it is
/// idle (`restartIfReplaced`, ChiefConversationOwner+Update.swift). Only
/// `local-conversations-v1` is required of it.
@Observable @MainActor
public final class ChiefConversationOwner {
    public let home: ChiefHome
    /// The live connection, nil while connecting or disconnected.
    public private(set) var connection: DaemonConnection?
    public private(set) var identity: DaemonIdentity?
    /// NIGHTLY's one-time backup of its shared home (`ChiefAdoption`), taken before the owner
    /// starts; nil until it ran or when it failed (the old Chief import waits for a later launch).
    public private(set) var adoption: ChiefAdoption.Outcome?
    /// Why the owner is not connected, for `debug.home`.
    public private(set) var lastError: String?
    /// The handshake's refusal of the owner's build (too old, another protocol): nil while it has
    /// not answered yet, for a timeout or a closed socket, and once it connects. Home says the
    /// daemon is too old only then, never while it is still connecting.
    public private(set) var refusal: DaemonCompatibility?
    /// Runs once on the first connection, before the connection is
    /// published (the move of the old per-tag Chiefs). It never holds the
    /// owner back: Home's availability does not wait for the move.
    @ObservationIgnored public var prepare: (@concurrent @Sendable (DaemonConnection) async -> Void)?
    /// Conversation events (`conversation-changed`, `conversation-typing`, the Home row events).
    @ObservationIgnored public var onEvent: ((DaemonEvent) -> Void)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let wake = RetryWake(owner: "ChiefConversationOwner")
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    public init(home: ChiefHome) {
        self.home = home
    }

    /// The owner's process environment: the app's, plus the brain host's
    /// tools socket, so `chief.engine.*` and `chief.stop` reach this home's
    /// brain (cmux-tui forwards them there, as chief-inspect), and the
    /// values the owner needs to run the other Chiefs' brains
    /// (`brainsValue`). An owner that another build already started keeps
    /// its environment until it restarts.
    static func ownerEnvironment(home: ChiefHome, process: [String: String], bundle: Bundle = .main) -> [String: String] {
        var environment = process
        environment["CMUX_TUI_CHIEF_TOOLS_SOCKET"] = home.muxHome.appendingPathComponent("optchat/tools.sock").path
        environment["CMUX_TUI_CHIEF_BRAINS"] = brainsValue(home: home, process: process, bundle: bundle)
        return environment
    }

    /// `start` ran and its connection loop runs (false: never started, or the launcher failed).
    public var isRunning: Bool { runTask != nil }

    public func supports(_ capability: String) -> Bool {
        connection != nil && identity?.supports(capability) == true
    }

    /// The owner's socket, once connected (the brain host's `--daemon-socket`).
    public func socketPath() async -> String? {
        await connection?.endpoint?.socketPath
    }

    /// Ensures the owner and keeps a connection to it. Idempotent.
    public func start(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard runTask == nil else { return }
        let launcher: DaemonLauncher
        do {
            launcher = try DaemonLauncher.forChief(session: home.session, stateDirectory: home.daemonStateDirectory,
                                                   bundle: bundle, processEnvironment: Self.ownerEnvironment(home: home, process: environment, bundle: bundle))
        } catch {
            lastError = String(describing: error)
            logger.error("chief owner: \(String(describing: error), privacy: .public)")
            return
        }
        // client-hello role main, with the install key the owner got at launch (an unsigned
        // build): the owner verifies this app, so it issues the page's gesture confirmations.
        let configuration = DaemonConnection.Configuration(
            clientName: "cmux-next-home",
            requiredCapabilities: [DaemonCapability.localConversations.rawValue],
            retryWake: wake,
            terminalEnvironment: nil,
            clientHello: ClientHelloIdentity(installKey: launcher.configuration.installKey))
        let provider = launcher.endpointProvider
        let wake = wake
        let logger = logger
        let home = home
        let build = bundle.bundleIdentifier ?? ChiefHome.nightlyBundleID
        // task-owner: lives as long as the app; one connection, reconnecting by itself
        runTask = Task { [weak self] in
            weak let weakSelf = self
            // NIGHTLY's backup before this app starts the owner (cx-is1kf.7); a running owner's
            // databases are copied with SQLite's online backup.
            // cmux NEXT's one-time adoption of its old homes ends before its owner starts (cx-is1kf.9).
            await AcpmuxEnvironment.adoptBuildHomes()
            let adoption = await ChiefAdoption.runOffMain(home: home, by: build, logger: logger)
            weakSelf?.adoption = adoption
            let connected = await DaemonStartup.shared.connect(wake: wake) {
                DaemonConnection(configuration: configuration, endpointProvider: provider)
            } onFailure: { error in
                logger.error("chief owner unavailable: \(error.description, privacy: .public)")
                await weakSelf?.noteFailure(error)
            }
            guard let (connection, identity) = connected else { return }
            guard let self, !Task.isCancelled else {
                await connection.close()
                return
            }
            // It answered as current: a refusal from an earlier try no longer holds while it gets ready below.
            self.noteHandshakeAccepted()
            // Before anything uses the connection: an owner without this home's key (DEV only) restarts once while
            // idle; a busy one (a Chief turn, an open `cmux chief` chat, another app or page) on a later owner event.
            // An owner an update replaced hands off to this build first (its successor starts with the
            // install key too, so no second restart is needed).
            let restart: IdleOwnerRestart?
            if let replaced = await Self.restartIfReplaced(launcher: launcher, connection: connection,
                                                           identity: identity, logger: logger) {
                restart = replaced
            } else {
                restart = await Self.restartIfUnverified(home: self.home, launcher: launcher, connection: connection,
                                                         identity: identity, logger: logger)
            }
            if let prepare = self.prepare { await prepare(connection) }
            self.attach(connection, identity: identity)
            // The waiting restart probes off this loop, so Home's events never wait for it; the newest
            // busy-ending event is enough (each one probes the owner afresh).
            let restartFeed = restart.map { restart in
                let (events, feed) = AsyncStream<DaemonEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
                // task-owner: this run task; ends when the feed finishes below or the restart is decided
                Task {
                    for await event in events {
                        if await restart.note(event) != .waiting { break }
                    }
                }
                return feed
            }
            do {
                for try await envelope in connection.events {
                    if IdleOwnerRestart.mayEndBusy(envelope.event) { restartFeed?.yield(envelope.event) }
                    self.handle(envelope.event, connection: connection)
                }
            } catch {}
            restartFeed?.finish()
            self.connection = nil
        }
    }

    /// Quit, end sessions: the owner ends with the other sessions. The
    /// connection closes first-hand after the request, so its reconnect
    /// never starts the owner again; its conversations stay on disk.
    public func shutdownForEndSessions() async {
        runTask?.cancel()
        guard let connection, let identity else { return }
        self.connection = nil
        _ = try? await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation))
        await connection.close()
    }

    func noteFailure(_ error: DaemonError) {
        lastError = error.description
        // A retry that times out after a refusal says nothing new about the build.
        if let refused = DaemonCompatibility(refusal: error) { refusal = refused }
    }

    /// The handshake succeeded: the owner's build is current, whatever an earlier try said.
    func noteHandshakeAccepted() {
        refusal = nil
    }

    private func attach(_ connection: DaemonConnection, identity: DaemonIdentity) {
        self.identity = identity
        self.connection = connection
        lastError = nil
        refusal = nil
        logger.info("chief owner \(identity.session, privacy: .public) (cmux-tui \(identity.version, privacy: .public)) for \(self.home.root.path, privacy: .public)")
    }

    private func handle(_ event: DaemonEvent, connection: DaemonConnection) {
        switch event {
        case .connected(let identity, _):
            attach(connection, identity: identity)
        case .disconnected(let reason):
            self.connection = nil
            lastError = reason
        case .conversationChanged, .conversationTyping, .conversationDraft, .conversationLive, .conversationRunChanged:
            onEvent?(event)
        case .unknown(let name, _) where HomeInboxSource.rowEvents.contains(name):
            onEvent?(event)
        default:
            break
        }
    }
}
