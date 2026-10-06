import CmuxNextDaemon
import Foundation
import Observation
import os

/// The owner of Home's conversations: the cmux-tui daemon session of the
/// Chief home (`ChiefHome.session`, state in `ChiefHome.daemonStateDirectory`),
/// shared by every build of one account (plans/cmux-next/home-state-ownership.md).
/// It is the single writer of the Chief conversation; the OptChat log is
/// written only by the one brain host of the same home, which catches up
/// from this owner after any stop, so the visible chat and the Chief's memory
/// stay one history whatever build opens Home.
///
/// A build's own daemon (its tag's session) still owns its workspaces,
/// terminals and the Home workspace's tabs; a conversation tab there points
/// at a conversation of this owner by id.
///
/// The owner process is detached and outlives every app; any build that
/// opens Home ensures it and attaches. It is never handed off to the
/// connecting build's binary: two builds open at once would restart it in
/// turn. Only `local-conversations-v1` is required of it.
@Observable @MainActor
final class ChiefConversationOwner {
    let home: ChiefHome
    /// The live connection, nil while connecting or disconnected.
    private(set) var connection: DaemonConnection?
    private(set) var identity: DaemonIdentity?
    /// Why the owner is not connected, for `debug.home`.
    private(set) var lastError: String?
    /// Conversation events (`conversation-changed`, `conversation-typing`).
    @ObservationIgnored var onEvent: ((DaemonEvent) -> Void)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private let wake = RetryWake(owner: "ChiefConversationOwner")
    @ObservationIgnored private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    init(home: ChiefHome) {
        self.home = home
    }

    func supports(_ capability: String) -> Bool {
        connection != nil && identity?.supports(capability) == true
    }

    /// The owner's socket, once connected (the brain host's `--daemon-socket`).
    func socketPath() async -> String? {
        await connection?.endpoint?.socketPath
    }

    /// Ensures the owner and keeps a connection to it. Idempotent.
    func start(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard runTask == nil else { return }
        let launcher: DaemonLauncher
        do {
            launcher = try DaemonLauncher.forChief(session: home.session, stateDirectory: home.daemonStateDirectory,
                                                   bundle: bundle, processEnvironment: environment)
        } catch {
            lastError = String(describing: error)
            logger.error("chief owner: \(String(describing: error), privacy: .public)")
            return
        }
        let configuration = DaemonConnection.Configuration(
            clientName: "cmux-next-home",
            requiredCapabilities: [DaemonCapabilities.shared.localConversations],
            retryWake: wake,
            terminalEnvironment: nil)
        let provider = launcher.endpointProvider
        let wake = wake
        let logger = logger
        // task-owner: lives as long as the app; one connection, reconnecting by itself
        runTask = Task { [weak self] in
            weak let weakSelf = self
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
            self.attach(connection, identity: identity)
            do {
                for try await envelope in connection.events {
                    self.handle(envelope.event, connection: connection)
                }
            } catch {}
            self.connection = nil
        }
    }

    private func noteFailure(_ error: DaemonError) {
        lastError = error.description
    }

    private func attach(_ connection: DaemonConnection, identity: DaemonIdentity) {
        self.identity = identity
        self.connection = connection
        lastError = nil
        logger.info("chief owner \(identity.session, privacy: .public) (cmux-tui \(identity.version, privacy: .public)) for \(self.home.root.path, privacy: .public)")
    }

    private func handle(_ event: DaemonEvent, connection: DaemonConnection) {
        switch event {
        case .connected(let identity, _):
            attach(connection, identity: identity)
        case .disconnected(let reason):
            self.connection = nil
            lastError = reason
        case .conversationChanged, .conversationTyping:
            onEvent?(event)
        default:
            break
        }
    }
}
