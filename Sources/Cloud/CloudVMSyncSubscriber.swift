import CmuxAuthRuntime
import CmuxCloud
import Foundation
import OSLog

nonisolated private let cloudVMSyncLog = Logger(subsystem: "dev.cmux", category: "cloud-vm-sync")

/// Keeps one machines panel subscribed to its team's `vms` sync collection on
/// the presence worker (`workers/presence/src/syncVms.ts`), so a machine
/// created, renamed, resumed or destroyed anywhere lands in the list within a
/// round trip instead of on the next REST poll.
///
/// Owns its own presence socket: ``DeviceDirectory`` exists only while device
/// discovery is on, and the Cloud list must stay live without it. The hello
/// asks for `vms` from the last cursor this instance applied (0/0 on the first
/// connect and after every scope change), so a reconnect after the server's
/// 15-minute deadline catches up with deltas. Every socket presents the same
/// team header ``VMClient`` sends (`X-Cmux-Team-Id` = `auth.resolvedTeamID`,
/// none for a personal account without teams), and its token source fails
/// closed once the account or team changes, at which point the owner calls
/// ``start()`` again and the subscriber resubscribes under the new scope.
///
/// Reconnect and backoff mirror ``DeviceDirectory``: `[1, 2, 5, 10, 30]` s
/// after a failure, at once after a clean close. Cloud availability and the
/// panel's lifecycle are the owner's decision (``MachinesPanelViewModel``
/// starts this with polling and stops it with polling).
@MainActor
final class CloudVMSyncSubscriber {
    /// What the owner receives, on the main actor, in stream order.
    enum Event: Equatable {
        /// A socket delivered its first frame; the owner re-reads the REST
        /// list because changes during the gap are not replayed in full.
        case connected
        /// A complete `vms` snapshot. `backfilled` false means the page set is
        /// partial and must never delete a row.
        case snapshot(records: [VMSyncRecord], backfilled: Bool)
        case delta(records: [VMSyncRecord])
        /// The socket ended or failed after `.connected`.
        case disconnected
    }

    enum State: Equatable, Sendable {
        case stopped
        case connecting
        case live
        case retrying(attempt: Int)
    }

    /// The account and team one socket is bound to.
    struct Scope: Equatable, Sendable {
        let identity: AuthenticatedSessionIdentity
        let teamID: String?
    }

    typealias SubscriberFactory = @Sendable (
        URL,
        [DevicePresenceFrame.SyncCollection],
        @escaping @Sendable () async throws -> DevicePresenceSubscriber.Credentials?
    ) -> DevicePresenceSubscriber

    nonisolated static let reconnectDelays: [Duration] = DeviceDirectory.reconnectDelays

    private(set) var state: State = .stopped
    private(set) var scope: Scope?
    /// The reconnect cursor: the `vms` head this instance last applied.
    private(set) var cursor = 0
    private(set) var epoch = 0

    private let auth: AuthCoordinator
    private let serviceURL: @MainActor @Sendable () -> URL?
    private let makeSubscriber: SubscriberFactory
    private let clock: any Clock<Duration>
    private var onEvent: @MainActor (Event) -> Void = { _ in }
    private var loopTask: Task<Void, Never>?
    private var pendingSnapshot: [VMSyncRecord] = []

    init(
        auth: AuthCoordinator,
        serviceURL: @escaping @MainActor @Sendable () -> URL? = { PresenceHeartbeatClient.resolvedServiceURL() },
        makeSubscriber: @escaping SubscriberFactory = { url, collections, credentials in
            DevicePresenceSubscriber(serviceBaseURL: url, collections: collections, credentials: credentials)
        },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.auth = auth
        self.serviceURL = serviceURL
        self.makeSubscriber = makeSubscriber
        self.clock = clock
    }

    deinit {
        // The loop holds this instance weakly, so an owner that is released
        // without stop() still ends the socket here.
        loopTask?.cancel()
    }

    /// Installs the owner's event handler; events are delivered on the main actor.
    func setEventHandler(_ handler: @escaping @MainActor (Event) -> Void) {
        onEvent = handler
    }

    var isRunning: Bool { loopTask != nil }

    /// The scope a socket opened now would bind to; nil while signed out.
    func currentScope() -> Scope? {
        guard let identity = auth.authenticatedSessionIdentity else { return nil }
        return Scope(identity: identity, teamID: auth.resolvedTeamID)
    }

    /// Subscribes under the current account and team. A running subscription
    /// under the same scope is kept (its cursor stays valid); a different scope
    /// or a signed-out account tears the socket down first, and a fresh scope
    /// starts from cursor 0 because cursors are per team.
    func start() {
        let next = currentScope()
        if loopTask != nil, next == scope { return }
        stop()
        guard let next else { return }
        scope = next
        cursor = 0
        epoch = 0
        let clock = clock
        loopTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                var connected = false
                do {
                    let frames: AsyncThrowingStream<DevicePresenceFrame, any Error>
                    do {
                        // Retain the owner only while opening the socket, never
                        // across the receive loop, so deinit can end the task.
                        guard let owner = self else { return }
                        frames = try await owner.openSocket(scope: next)
                    }
                    for try await frame in frames {
                        guard !Task.isCancelled, let owner = self else { return }
                        if !connected {
                            connected = true
                            failures = 0
                            owner.streamDidConnect()
                        }
                        owner.apply(frame)
                    }
                    // A clean close is the server's token deadline: resubscribe at once.
                    failures = 0
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    cloudVMSyncLog.error("vms subscribe failed: \(String(describing: error), privacy: .private)")
                }
                guard !Task.isCancelled, let owner = self else { return }
                owner.streamDidEnd(wasConnected: connected, failures: failures)
                let delay = Self.reconnectDelays[min(max(failures - 1, 0), Self.reconnectDelays.count - 1)]
                // Bounded, cancellable backoff between subscribe attempts; the
                // cancellation is wired to stop() through the owning task.
                guard (try? await clock.sleep(for: failures == 0 ? .zero : delay)) != nil else { return }
            }
        }
    }

    func stop() {
        let wasLive = state == .live
        loopTask?.cancel()
        loopTask = nil
        scope = nil
        pendingSnapshot = []
        cursor = 0
        epoch = 0
        state = .stopped
        if wasLive { onEvent(.disconnected) }
    }

    private func openSocket(scope: Scope) async throws -> AsyncThrowingStream<DevicePresenceFrame, any Error> {
        // Configuration can arrive after startup. A missing endpoint follows
        // the same cancellable recovery as a failed connection.
        guard let url = serviceURL() else {
            throw DevicePresenceSubscriber.SubscribeError.invalidServiceURL
        }
        state = .connecting
        pendingSnapshot = []
        let tokens = HiveAccountTokenSource(auth: auth, identity: scope.identity, teamID: scope.teamID)
        let teamID = scope.teamID
        let collections = [DevicePresenceFrame.SyncCollection(
            name: DevicePresenceFrame.vmsCollection, cursor: cursor, epoch: epoch
        )]
        let subscriber = makeSubscriber(url, collections) {
            // The same header rule as VMClient: the resolved team id, omitted
            // for a personal account; the token source fails closed on a switch.
            let session = try await tokens.session()
            return DevicePresenceSubscriber.Credentials(accessToken: session.accessToken, teamID: teamID)
        }
        return try await subscriber.subscribe()
    }

    private func streamDidConnect() {
        state = .live
        onEvent(.connected)
    }

    private func streamDidEnd(wasConnected: Bool, failures: Int) {
        state = .retrying(attempt: failures)
        if wasConnected { onEvent(.disconnected) }
    }

    /// Reduce one frame: buffer snapshot pages until `complete`, advance the
    /// cursor only for frames the owner receives, ignore everything else.
    func apply(_ frame: DevicePresenceFrame) {
        switch frame {
        case .vmsSnapshot(let records, let complete, let backfilled, let snapshotRev, let epoch):
            pendingSnapshot.append(contentsOf: records)
            guard complete else { return }
            let all = pendingSnapshot
            pendingSnapshot = []
            cursor = snapshotRev
            self.epoch = epoch
            onEvent(.snapshot(records: all, backfilled: backfilled))
        case .vmsDelta(let records, let rev):
            cursor = max(cursor, rev)
            onEvent(.delta(records: records))
        case .snapshot, .online, .offline, .seen, .routes, .syncSnapshot, .syncDelta, .ignored:
            return
        }
    }
}
