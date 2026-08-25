public import CMUXMobileCore
public import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation
public import Observation

/// A live viewing session onto one paired Mac: the persistent RPC client,
/// the remote workspace list, and reconnect recovery.
///
/// The macOS counterpart of the iOS shell's per-Mac connection: it dials the
/// paired Mac's routes in priority order over the shared
/// ``MobileCoreRPCClient`` (multiplexed, lazily reconnecting transport),
/// fetches `workspace.list`, and keeps the list fresh from `workspace.updated`
/// push events. When the event stream dies (network blip, host restart) the
/// session re-subscribes with a bounded backoff — the client reconnects the
/// transport on the next request — so recovery needs no relaunch.
@MainActor
@Observable
public final class HiveRemoteMacSession {
    /// The session's connection lifecycle state.
    public enum Phase: Equatable, Sendable {
        /// No connection attempt yet.
        case idle
        /// Dialing routes / fetching the initial workspace list.
        case connecting
        /// Connected; the workspace list is live.
        case connected
        /// Connection lost; the session is retrying in the background.
        case reconnecting
        /// All routes failed; `message` is the last error's description.
        case failed(message: String)
    }

    /// The paired Mac's stable device id.
    public let macDeviceID: String
    /// The paired Mac's display name (for the window title).
    public let displayName: String
    /// The currently selected route set; a changed registry/presence snapshot
    /// causes the app service to replace this session before reconnecting.
    public let routes: [CmxAttachRoute]
    /// The registry route snapshot from which ``routes`` was admitted. Used to
    /// detect binding changes without re-running the local Tailscale proof on
    /// every presence update.
    public let sourceRoutes: [CmxAttachRoute]
    /// The registry instance tag this session was bound to, when available.
    public let expectedInstanceTag: String?
    /// Whether this session requires the authenticated host-identity gate.
    public let requiresHostIdentity: Bool

    /// Connection lifecycle state.
    public private(set) var phase: Phase = .idle
    /// The remote workspace list, in host order.
    public private(set) var workspaces: [HiveRemoteWorkspace] = []

    @ObservationIgnored private let runtime: any MobileSyncRuntime
    @ObservationIgnored private let retryDelay: @Sendable (_ attempt: Int) async -> Void
    @ObservationIgnored private let workspaceDecoder: HiveRemoteWorkspaceDecoder
    @ObservationIgnored private let stackAuthChannelTrust: MobileShellRouteAuthPolicy.StackAuthChannelTrust
    /// The connected RPC client terminal sessions share, `nil` until the
    /// first successful connect.
    @ObservationIgnored public private(set) var client: MobileCoreRPCClient?
    /// One surface-scoped render-grid router shared by all terminal sessions
    /// attached to this Mac.
    @ObservationIgnored public private(set) var renderGridRouter: HiveRemoteRenderGridRouter?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var workspaceRefreshTask: Task<Bool, Never>?
    @ObservationIgnored private var workspaceRefreshPending = false
    @ObservationIgnored private var workspaceListeners:
        [UUID: AsyncStream<[HiveRemoteWorkspace]>.Continuation] = [:]

    /// Creates a session onto one paired Mac.
    ///
    /// - Parameters:
    ///   - runtime: The shared sync runtime (transport factory + Stack tokens).
    ///   - macDeviceID: The Mac's stable device id.
    ///   - displayName: The Mac's display name.
    ///   - routes: The paired record's attach routes.
    ///   - sourceRoutes: The unmodified registry routes used for binding-change
    ///     comparisons, when `routes` has been canonicalized by admission.
    ///   - retryDelay: Awaited between reconnect attempts with the
    ///     consecutive-failure count; production passes a bounded backoff
    ///     sleep, tests a recorder that returns immediately.
    ///   - stackAuthChannelTrust: The route provenance trusted to carry the
    ///     account token. Manual links default to loopback-only.
    ///   - expectedInstanceTag: The registry instance tag, when known.
    ///   - requiresHostIdentity: Require mobile.host.status to match the
    ///     registry device before accepting workspace data.
    public init(
        runtime: any MobileSyncRuntime,
        macDeviceID: String,
        displayName: String,
        routes: [CmxAttachRoute],
        sourceRoutes: [CmxAttachRoute]? = nil,
        retryDelay: @escaping @Sendable (_ attempt: Int) async -> Void,
        stackAuthChannelTrust: MobileShellRouteAuthPolicy.StackAuthChannelTrust = .loopbackOnly,
        expectedInstanceTag: String? = nil,
        requiresHostIdentity: Bool = true
    ) {
        self.runtime = runtime
        self.macDeviceID = macDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayName = displayName
        self.routes = routes
        self.sourceRoutes = sourceRoutes ?? routes
        self.expectedInstanceTag = expectedInstanceTag
        self.requiresHostIdentity = requiresHostIdentity
        self.retryDelay = retryDelay
        self.workspaceDecoder = HiveRemoteWorkspaceDecoder()
        self.stackAuthChannelTrust = stackAuthChannelTrust
    }

    /// Start (or restart) the session: dial routes, fetch the workspace list,
    /// and begin observing workspace updates. Idempotent while a connect is
    /// already in flight.
    public func connect() {
        guard connectTask == nil else { return }
        phase = .connecting
        connectTask = Task { [weak self] in
            await self?.runConnect()
            self?.connectTask = nil
        }
    }

    /// Tear down the session (window closed).
    public func disconnect() async {
        let pendingConnect = connectTask
        pendingConnect?.cancel()
        await pendingConnect?.value
        connectTask = nil
        let pendingEvents = eventTask
        pendingEvents?.cancel()
        await pendingEvents?.value
        eventTask = nil
        workspaceRefreshTask?.cancel()
        workspaceRefreshTask = nil
        workspaceRefreshPending = false
        renderGridRouter?.stop()
        renderGridRouter = nil
        if let client {
            await client.disconnect()
        }
        client = nil
        phase = .idle
    }

    /// Re-fetch the workspace list from the connected Mac.
    @discardableResult
    public func refreshWorkspaces() async -> Bool {
        scheduleWorkspaceRefresh()
        return await workspaceRefreshTask?.value ?? false
    }

    /// Creates a terminal session using this Mac's shared surface-scoped event
    /// router. Returns `nil` until the initial RPC client is connected.
    /// - Parameters:
    ///   - workspaceID: The remote workspace containing the terminal.
    ///   - terminalID: The remote terminal/surface identifier.
    ///   - retryDelay: Backoff used while reattaching after a transport drop.
    public func makeTerminalSession(
        workspaceID: String,
        terminalID: String,
        retryDelay: @escaping @Sendable (_ attempt: Int) async -> Void
    ) -> HiveRemoteTerminalSession? {
        guard let client else { return nil }
        return HiveRemoteTerminalSession(
            client: client,
            workspaceID: workspaceID,
            terminalID: terminalID,
            retryDelay: retryDelay,
            renderGridRouter: renderGridRouter
        )
    }

    private func scheduleWorkspaceRefresh() {
        guard workspaceRefreshTask == nil else {
            workspaceRefreshPending = true
            return
        }
        workspaceRefreshTask = Task { [weak self] in
            guard let self else { return false }
            let succeeded = await self.performWorkspaceRefresh()
            self.workspaceRefreshTask = nil
            guard !Task.isCancelled else {
                self.workspaceRefreshPending = false
                return succeeded
            }
            if self.workspaceRefreshPending {
                self.workspaceRefreshPending = false
                self.scheduleWorkspaceRefresh()
            }
            return succeeded
        }
    }

    private func performWorkspaceRefresh() async -> Bool {
        guard !Task.isCancelled, let client else { return false }
        do {
            let refreshed = try await fetchWorkspaces(client: client)
            guard !Task.isCancelled else { return false }
            setWorkspaces(refreshed)
            return true
        } catch {
            // Keep the stale list; the event loop's stream death drives the
            // visible reconnect state.
            return false
        }
    }

    /// A stream of workspace lists: the current value immediately, then every
    /// change (the session refreshes on `workspace.updated` push events).
    /// Native mirror reconciliation consumes this to add/remove local mirror
    /// workspaces as the host's topology changes.
    public func workspaceUpdates() -> AsyncStream<[HiveRemoteWorkspace]> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<[HiveRemoteWorkspace]>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        workspaceListeners[id] = continuation
        continuation.yield(workspaces)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.workspaceListeners.removeValue(forKey: id)
            }
        }
        return stream
    }

    private func setWorkspaces(_ newWorkspaces: [HiveRemoteWorkspace]) {
        workspaces = newWorkspaces
        for (_, continuation) in workspaceListeners {
            continuation.yield(newWorkspaces)
        }
    }

    // MARK: - Connect

    private func runConnect() async {
        let supported = Set(runtime.supportedRouteKinds)
        let candidates = routes
            .filter { supported.contains($0.kind) }
            .sorted { $0.priority < $1.priority }
        guard !candidates.isEmpty else {
            guard !Task.isCancelled else { return }
            phase = .failed(message: Self.noRouteMessage)
            return
        }
        var lastError: (any Error)?
        for route in candidates {
            if Task.isCancelled { return }
            guard let ticket = Self.viewerTicket(
                macDeviceID: macDeviceID,
                displayName: displayName,
                route: route
            ) else { continue }
            // Mac-to-Mac viewer: routes come from the signed-in account's own
            // device registry, so the WireGuard-encrypted Tailscale tunnel is
            // trusted to carry the Stack token (iOS stays loopback-only).
            let candidate = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: true,
                stackAuthChannelTrust: stackAuthChannelTrust
            )
            do {
                if requiresHostIdentity {
                    try await verifyHostIdentity(client: candidate)
                }
                let workspaces = try await fetchWorkspaces(client: candidate)
                // Complete the host-side event subscription before publishing
                // `.connected` or handing the shared render router to a
                // terminal session. Otherwise a replay can race the first
                // `mobile.events.subscribe` request and lose early deltas.
                try await subscribeToHostEvents(client: candidate)
                // disconnect() can cancel this task while the RPC is
                // suspended. Do not resurrect a session after teardown.
                guard !Task.isCancelled else {
                    await candidate.disconnect()
                    return
                }
                renderGridRouter?.stop()
                renderGridRouter = nil
                if let previous = client { await previous.disconnect() }
                client = candidate
                renderGridRouter = HiveRemoteRenderGridRouter(client: candidate)
                setWorkspaces(workspaces)
                phase = .connected
                startEventLoop(client: candidate)
                return
            } catch {
                lastError = error
                await candidate.disconnect()
            }
        }
        guard !Task.isCancelled else { return }
        // Upstream transport/decoding errors can contain addresses, request
        // ids, or other implementation details. Keep the viewer's failure
        // state product-facing and localized instead of exposing them.
        phase = .failed(message: lastError == nil
            ? Self.noRouteMessage
            : Self.connectionFailedMessage)
    }

    /// A route-carrier ticket for the viewer. It authorizes nothing (no
    /// attach token — Stack auth is the host's sole gate); the non-empty
    /// workspace id only namespaces it, mirroring the iOS manual-host flow.
    static func viewerTicket(
        macDeviceID: String,
        displayName: String,
        route: CmxAttachRoute
    ) -> CmxAttachTicket? {
        try? CmxAttachTicket(
            workspaceID: "hive-viewer",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route]
        )
    }

    private func fetchWorkspaces(client: MobileCoreRPCClient) async throws -> [HiveRemoteWorkspace] {
        let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list")
        let data = try await client.sendRequest(request)
        let decoder = workspaceDecoder
        return try await Task.detached(priority: .userInitiated) {
            try decoder.decode(data)
        }.value
    }

    private func verifyHostIdentity(client: MobileCoreRPCClient) async throws {
        let request = try MobileCoreRPCClient.requestData(method: "mobile.host.status")
        let data = try await client.sendRequest(request)
        let status = try await Task.detached(priority: .userInitiated) {
            try MobileHostStatusResponse.decode(data)
        }.value
        guard status.macDeviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == macDeviceID,
              expectedInstanceTag == nil || status.macInstanceTag == expectedInstanceTag else {
            throw HiveRemoteTerminalSessionError.hostIdentityMismatch
        }
    }

    // MARK: - Events

    private func subscribeToHostEvents(client: MobileCoreRPCClient) async throws {
        let subscribe = try MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: ["topics": ["workspace.updated", "terminal.render_grid"]]
        )
        _ = try await client.sendRequest(subscribe)
    }

    private func startEventLoop(client: MobileCoreRPCClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.runEventLoop(client: client)
        }
    }

    private func runEventLoop(client: MobileCoreRPCClient) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            do {
                // Register the subscription host-side; this also reconnects a
                // torn-down transport, which is the recovery path after a blip.
                try await subscribeToHostEvents(client: client)
                consecutiveFailures = 0
                guard !Task.isCancelled else { return }
                phase = .connected
                // Refresh before installing the local listener. If setup or
                // the refresh fails, no AsyncStream continuation has been
                // registered and the retry cannot leak an orphan listener.
                guard await refreshWorkspaces() else {
                    consecutiveFailures += 1
                    phase = .reconnecting
                    await retryDelay(consecutiveFailures)
                    continue
                }
                guard !Task.isCancelled else { return }
                let stream = await client.subscribe(to: ["workspace.updated"])
                // The refresh closes the small handshake/listener race: any
                // event emitted before the listener was installed is reflected
                // in the authoritative snapshot above.
                for await _ in stream {
                    scheduleWorkspaceRefresh()
                }
                if Task.isCancelled { return }
                phase = .reconnecting
                consecutiveFailures += 1
                await retryDelay(consecutiveFailures)
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                if Task.isCancelled { return }
                phase = .reconnecting
                await retryDelay(consecutiveFailures)
                continue
            }
        }
    }

    private static var noRouteMessage: String {
        String(
            localized: "hive.viewer.error.noRoute",
            defaultValue: "This computer hasn't advertised a reachable address. Make sure Tailscale is running on both Macs."
        )
    }

    private static var connectionFailedMessage: String {
        String(
            localized: "hive.viewer.error.connection",
            defaultValue: "The other Mac couldn't be reached. Check that it is online and paired, then try again."
        )
    }
}
