public import CMUXMobileCore
public import CmuxMobileRPC
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

    /// Connection lifecycle state.
    public private(set) var phase: Phase = .idle
    /// The remote workspace list, in host order.
    public private(set) var workspaces: [HiveRemoteWorkspace] = []

    @ObservationIgnored private let runtime: any MobileSyncRuntime
    @ObservationIgnored private let routes: [CmxAttachRoute]
    @ObservationIgnored private let retryDelay: @Sendable (_ attempt: Int) async -> Void
    /// The connected RPC client terminal sessions share, `nil` until the
    /// first successful connect.
    @ObservationIgnored public private(set) var client: MobileCoreRPCClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    /// Creates a session onto one paired Mac.
    ///
    /// - Parameters:
    ///   - runtime: The shared sync runtime (transport factory + Stack tokens).
    ///   - macDeviceID: The Mac's stable device id.
    ///   - displayName: The Mac's display name.
    ///   - routes: The paired record's attach routes.
    ///   - retryDelay: Awaited between reconnect attempts with the
    ///     consecutive-failure count; production passes a bounded backoff
    ///     sleep, tests a recorder that returns immediately.
    public init(
        runtime: any MobileSyncRuntime,
        macDeviceID: String,
        displayName: String,
        routes: [CmxAttachRoute],
        retryDelay: @escaping @Sendable (_ attempt: Int) async -> Void
    ) {
        self.runtime = runtime
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.routes = routes
        self.retryDelay = retryDelay
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
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        if let client {
            await client.disconnect()
        }
        client = nil
        phase = .idle
    }

    /// Re-fetch the workspace list from the connected Mac.
    public func refreshWorkspaces() async {
        guard let client else { return }
        do {
            workspaces = try await Self.fetchWorkspaces(client: client)
        } catch {
            // Keep the stale list; the event loop's stream death drives the
            // visible reconnect state.
        }
    }

    // MARK: - Connect

    private func runConnect() async {
        let supported = Set(runtime.supportedRouteKinds)
        let candidates = routes
            .filter { supported.contains($0.kind) }
            .sorted { $0.priority < $1.priority }
        guard !candidates.isEmpty else {
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
                stackAuthChannelTrust: .loopbackAndTailscaleTunnel
            )
            do {
                let workspaces = try await Self.fetchWorkspaces(client: candidate)
                if let previous = client { await previous.disconnect() }
                client = candidate
                self.workspaces = workspaces
                phase = .connected
                startEventLoop(client: candidate)
                return
            } catch {
                lastError = error
                await candidate.disconnect()
            }
        }
        phase = .failed(message: (lastError as? MobileShellConnectionError)?.localizedDescription
            ?? lastError.map(String.init(describing:))
            ?? Self.noRouteMessage)
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

    private static func fetchWorkspaces(client: MobileCoreRPCClient) async throws -> [HiveRemoteWorkspace] {
        let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list")
        let data = try await client.sendRequest(request)
        let response = try MobileSyncWorkspaceListResponse.decode(data)
        return response.workspaces.map { workspace in
            HiveRemoteWorkspace(
                id: workspace.id,
                title: workspace.title,
                isSelected: workspace.isSelected,
                terminals: workspace.terminals.map {
                    HiveRemoteWorkspace.Terminal(id: $0.id, title: $0.title, isFocused: $0.isFocused)
                }
            )
        }
    }

    // MARK: - Events

    private func startEventLoop(client: MobileCoreRPCClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            await self?.runEventLoop(client: client)
        }
    }

    private func runEventLoop(client: MobileCoreRPCClient) async {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            let stream = await client.subscribe(to: ["workspace.updated"])
            do {
                // Register the subscription host-side; this also reconnects a
                // torn-down transport, which is the recovery path after a blip.
                let subscribe = try MobileCoreRPCClient.requestData(
                    method: "mobile.events.subscribe",
                    params: ["topics": ["workspace.updated"]]
                )
                _ = try await client.sendRequest(subscribe)
                consecutiveFailures = 0
                phase = .connected
                await refreshWorkspaces()
            } catch is CancellationError {
                return
            } catch {
                consecutiveFailures += 1
                if Task.isCancelled { return }
                phase = .reconnecting
                await retryDelay(consecutiveFailures)
                continue
            }
            for await _ in stream {
                await refreshWorkspaces()
            }
            // Stream finished: the transport died. Loop to re-subscribe.
            if Task.isCancelled { return }
            phase = .reconnecting
            consecutiveFailures += 1
            await retryDelay(consecutiveFailures)
        }
    }

    private static var noRouteMessage: String {
        String(
            localized: "hive.viewer.error.noRoute",
            defaultValue: "This computer hasn't advertised a reachable address. Make sure Tailscale is running on both Macs."
        )
    }
}
