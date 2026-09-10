import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation
import OSLog

private let deviceDirectoryLog = Logger(subsystem: "dev.cmux", category: "device-directory")

/// The account's other Macs, merged from the pairing store (local-first), the
/// durable device registry, and the live presence stream, excluding this exact
/// app instance. Bound to one account generation and team scope: the registry
/// rebuilds it when either changes, and every token it uses fails closed after.
///
/// Liveness is push: one presence WebSocket subscription (snapshot first, then
/// transitions, plus the `devices` sync collection for owners) reconnects with
/// bounded backoff whenever the server closes it or the network drops. The
/// registry is read on start, on an explicit refresh, and whenever the presence
/// stream reconnects (its snapshot marks the moment the picture may have
/// changed), as the durable fallback for devices presence has already
/// forgotten; it is never polled, and never how a device is found to be online.
@MainActor
@Observable
final class DeviceDirectory {
    enum PresenceState: Equatable, Sendable {
        case stopped
        case connecting
        case live
        /// The stream ended or failed; reconnecting after `attempt` failures.
        case retrying(attempt: Int, error: String)
    }

    static let didChangeNotification = Notification.Name("cmux.devices.directoryDidChange")

    private(set) var records: [DeviceDirectoryRecord] = []
    private(set) var presenceState: PresenceState = .stopped
    private(set) var registryError: String?
    private(set) var hasLoadedRegistry = false
    private(set) var isRefreshingRegistry = false

    /// Notifications describe the whole UI snapshot, not only its rows. A
    /// status transition is observable even when the directory stays empty.
    private struct PublishedState: Equatable {
        let records: [DeviceDirectoryRecord]
        let presenceState: PresenceState
        let registryError: String?
        let hasLoadedRegistry: Bool
        let isRefreshingRegistry: Bool
    }

    private var lastPublishedState: PublishedState?

    private let identity: AuthenticatedSessionIdentity
    private let teamID: String?
    private let tokens: HiveAccountTokenSource
    private let pairing: any DeviceLinkAuthorizationSource
    private let registryClient: DeviceRegistryDirectoryClient
    private let makeSubscriber: @Sendable (URL, @escaping @Sendable () async throws -> DevicePresenceSubscriber.Credentials?) -> DevicePresenceSubscriber
    private let serviceURL: @MainActor @Sendable () -> URL?
    private let selfInstance: SurfaceDeviceInstanceID
    private let clock: any Clock<Duration>

    private var registryDevices: [DeviceRegistryDirectoryClient.Device] = []
    private var presenceInstances: [SurfaceDeviceInstanceID: DevicePresenceInstance] = [:]
    private var owners: [String: String] = [:]
    private var ownersKnown = false
    private var pendingSyncSnapshot: [DeviceSyncRecord] = []
    private var presenceTask: Task<Void, Never>?
    private var registryTask: Task<Void, Never>?
    private var pairingObserver: NSObjectProtocol?
    /// Presence snapshots received since start; the first one follows the
    /// start-time registry read, later ones mark a reconnect.
    private var presenceSnapshots = 0

    nonisolated static let reconnectDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)]

    init(
        auth: AuthCoordinator,
        identity: AuthenticatedSessionIdentity,
        teamID: String?,
        pairing: any DeviceLinkAuthorizationSource,
        registryClient: DeviceRegistryDirectoryClient? = nil,
        serviceURL: @escaping @MainActor @Sendable () -> URL? = { PresenceHeartbeatClient.resolvedServiceURL() },
        makeSubscriber: @escaping @Sendable (URL, @escaping @Sendable () async throws -> DevicePresenceSubscriber.Credentials?) -> DevicePresenceSubscriber = { url, credentials in
            DevicePresenceSubscriber(serviceBaseURL: url, credentials: credentials)
        },
        selfInstance: SurfaceDeviceInstanceID = SurfaceDeviceInstanceID(
            deviceID: MobileHostIdentity.deviceID(),
            tag: MobileHostIdentity.instanceTag()
        ),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.identity = identity
        self.teamID = teamID
        self.pairing = pairing
        let tokens = HiveAccountTokenSource(auth: auth, identity: identity, teamID: teamID)
        self.tokens = tokens
        self.registryClient = registryClient ?? DeviceRegistryDirectoryClient(
            session: { try await tokens.session() },
            teamID: teamID
        )
        self.serviceURL = serviceURL
        self.makeSubscriber = makeSubscriber
        self.selfInstance = selfInstance
        self.clock = clock
    }

    var isRunning: Bool { presenceTask != nil }

    func start() {
        guard presenceTask == nil else { return }
        pairingObserver = NotificationCenter.default.addObserver(
            forName: pairing.authorizationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.remerge() }
        }
        remerge()
        refreshRegistry()
        presenceTask = Task { [weak self] in await self?.runPresenceLoop() }
    }

    func stop() {
        if let pairingObserver { NotificationCenter.default.removeObserver(pairingObserver) }
        pairingObserver = nil
        presenceTask?.cancel()
        presenceTask = nil
        registryTask?.cancel()
        registryTask = nil
        isRefreshingRegistry = false
        presenceState = .stopped
        presenceInstances = [:]
        owners = [:]
        ownersKnown = false
        pendingSyncSnapshot = []
        presenceSnapshots = 0
        registryDevices = []
        records = []
        hasLoadedRegistry = false
        registryError = nil
        notifyChanged()
    }

    /// The explicit Refresh verb: re-read the registry now. Presence needs no
    /// refresh; it is already live.
    @discardableResult
    func refreshRegistry() -> Task<Void, Never> {
        if let registryTask { return registryTask }
        isRefreshingRegistry = true
        notifyChanged()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let devices = try await self.registryClient.list()
                self.registryDevices = devices
                self.registryError = nil
            } catch DeviceRegistryDirectoryClient.ListError.notSignedIn {
                self.registryError = nil
            } catch {
                self.registryError = String(describing: error)
                deviceDirectoryLog.error("device registry list failed: \(String(describing: error), privacy: .public)")
            }
            self.hasLoadedRegistry = true
            self.isRefreshingRegistry = false
            self.registryTask = nil
            self.remerge()
        }
        registryTask = task
        return task
    }

    // MARK: - Presence loop

    private func runPresenceLoop() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                // Configuration can arrive after startup. A missing endpoint
                // follows the same cancellable recovery as a failed connection.
                guard let url = serviceURL() else {
                    throw DevicePresenceSubscriber.SubscribeError.invalidServiceURL
                }
                presenceState = .connecting
                notifyChanged()
                let tokens = self.tokens
                let teamID = self.teamID
                let subscriber = makeSubscriber(url) {
                    let session = try await tokens.session()
                    return DevicePresenceSubscriber.Credentials(accessToken: session.accessToken, teamID: teamID)
                }
                let frames = try await subscriber.subscribe()
                for try await frame in frames {
                    if Task.isCancelled { return }
                    if case .snapshot = frame { failures = 0 }
                    apply(frame)
                }
                // A clean close is the server's token deadline: resubscribe at once.
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                deviceDirectoryLog.error("presence subscribe failed: \(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            let delay = Self.reconnectDelays[min(max(failures - 1, 0), Self.reconnectDelays.count - 1)]
            presenceState = .retrying(attempt: failures, error: presenceState == .live ? "stream ended" : "presence unreachable")
            notifyChanged()
            // Bounded, cancellable backoff between subscribe attempts; the
            // cancellation is wired to stop() through the owning task.
            guard (try? await clock.sleep(for: failures == 0 ? .zero : delay)) != nil else { return }
        }
    }

    /// Reduce one stream frame into the presence and owner maps. Pure over the
    /// directory's own state so the merge stays the single place records form.
    func apply(_ frame: DevicePresenceFrame) {
        switch frame {
        case .snapshot(let devices):
            // The first frame on a new socket starts a fresh ownership page
            // set. Never carry an interrupted snapshot across connections.
            pendingSyncSnapshot = []
            presenceInstances = [:]
            for device in devices {
                for instance in device.instances {
                    presenceInstances[instance.instanceID] = instance
                }
            }
            presenceState = .live
            presenceSnapshots += 1
            // A reconnect's snapshot: the registry may have changed while the
            // stream was down (a renamed or removed device), so re-read it now.
            if presenceSnapshots > 1 {
                refreshRegistry()
            }
        case .online(let instance), .routes(let instance):
            presenceInstances[instance.instanceID] = instance
        case .offline(let instance):
            presenceInstances[instance.instanceID] = instance
        case .seen(let deviceId, let tag, let lastSeenAt):
            let id = SurfaceDeviceInstanceID(deviceID: deviceId, tag: tag)
            if let existing = presenceInstances[id] {
                presenceInstances[id] = DevicePresenceInstance(
                    deviceId: existing.deviceId, tag: existing.tag, platform: existing.platform,
                    displayName: existing.displayName, bundleId: existing.bundleId,
                    online: existing.online, lastSeenAt: lastSeenAt, routes: existing.routes
                )
            }
        case .syncSnapshot(let records, let complete):
            pendingSyncSnapshot.append(contentsOf: records)
            guard complete else { return }
            var next: [String: String] = [:]
            for record in pendingSyncSnapshot where !record.deleted {
                if let device = record.device, let owner = device.ownerUserId {
                    next[cmxCanonicalDeviceID(device.deviceId)] = owner
                }
            }
            pendingSyncSnapshot = []
            owners = next
            ownersKnown = true
        case .syncDelta(let records):
            for record in records {
                if record.deleted {
                    owners[cmxCanonicalDeviceID(record.id)] = nil
                } else if let device = record.device, let owner = device.ownerUserId {
                    owners[cmxCanonicalDeviceID(device.deviceId)] = owner
                }
            }
        case .ignored:
            return
        }
        remerge()
    }

    private func remerge() {
        let merged = DeviceDirectoryMerge.merge(DeviceDirectoryMerge.Input(
            registry: registryDevices,
            presence: presenceInstances,
            presenceLive: presenceState == .live,
            owners: owners,
            ownersKnown: ownersKnown,
            paired: pairing.pairedDevices,
            previous: records,
            selfInstance: selfInstance,
            currentUserID: identity.accountID,
            resolvedTeamID: teamID
        ))
        if merged != records { records = merged }
        notifyChanged()
    }

    private func notifyChanged() {
        let state = PublishedState(
            records: records,
            presenceState: presenceState,
            registryError: registryError,
            hasLoadedRegistry: hasLoadedRegistry,
            isRefreshingRegistry: isRefreshingRegistry
        )
        guard state != lastPublishedState else { return }
        lastPublishedState = state
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }
}
