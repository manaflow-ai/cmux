internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import CmuxMobileSupport
internal import CmuxMobileTransport
internal import Foundation
import Observation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// The connection lifecycle carved out of ``MobileShellComposite``.
///
/// Owns pairing entry (preview code, pairing URL, manual host), attach-ticket
/// minting and route selection, `connect`, reconnect-on-launch from the
/// paired-Mac repository, disconnect/forget, authorization-failure handling,
/// and user-facing connection-error localization. It holds
/// `connectionState`/`connectionError`/`activeTicket`/`activeRoute`/
/// `connectedHostName` plus the active RPC client, and reaches the facade's
/// other pieces through the ``MobileConnectionContext`` seam.
///
/// The hand-rolled `pairingAttemptID` and `connectionGeneration` UUID guards
/// move here verbatim. They are deliberately not converted to structured task
/// ownership: pairing attempts are initiated by *callers'* async contexts
/// (SwiftUI actions, the recovery coordinator, URL handlers), so there is no
/// single owned task whose cancellation could replace the "is this still the
/// current attempt?" re-check after every suspension point.
@MainActor
@Observable
final class MobileConnectionCoordinator {
    var connectionState: MobileConnectionState
    var macConnectionStatus: MobileMacConnectionStatus
    var connectedHostName: String
    var connectionError: String?
    /// True when the host rejected this device on authorization grounds.
    /// Cleared on a healthy connection or an explicit disconnect-and-forget.
    var connectionRequiresReauth: Bool = false
    var pairingCode: String
    private(set) var activeTicket: CmxAttachTicket?
    private(set) var activeRoute: CmxAttachRoute?
    /// The active RPC client. The facade and its carved pieces compare this
    /// by identity (`===`) so stale responses can never mutate newer state.
    private(set) var remoteClient: MobileCoreRPCClient? {
        didSet {
            if remoteClient == nil {
                context?.remoteClientWasCleared()
            }
        }
    }
    private(set) var connectionGeneration: UUID
    private var pairingAttemptID: UUID
    private var workspaceListRefreshTask: Task<Void, Never>?

    private let runtime: (any MobileSyncRuntime)?
    /// The paired-Mac repository. Internal (not `private`): read by the
    /// facade's recovery-context conformance.
    let pairedMacStore: (any MobilePairedMacStoring)?
    private let identityProvider: (any MobileIdentityProviding)?
    /// Sibling coordinator whose `isRecoveringConnection`/
    /// `connectionRecoveryFailed` flags the `markMacConnection*` transitions
    /// keep in sync (one-way edge; recovery never references this type).
    private let recovery: MobileRecoveryCoordinator
    /// The facade. Weak: the facade owns this coordinator strongly, so this
    /// back-edge must not retain it.
    private weak var context: (any MobileConnectionContext)?

    var hasActiveUnexpiredAttachTicket: Bool {
        guard let activeTicket,
              activeTicket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return Self.attachTicketIsUnexpired(activeTicket, now: runtime?.now() ?? Date())
    }

    init(
        runtime: (any MobileSyncRuntime)?,
        pairedMacStore: (any MobilePairedMacStoring)?,
        identityProvider: (any MobileIdentityProviding)?,
        recovery: MobileRecoveryCoordinator,
        connectionState: MobileConnectionState,
        connectedHostName: String,
        pairingCode: String
    ) {
        self.runtime = runtime
        self.pairedMacStore = pairedMacStore
        self.identityProvider = identityProvider
        self.recovery = recovery
        self.connectionState = connectionState
        self.macConnectionStatus = connectionState == .connected ? .connected : .unavailable
        self.connectedHostName = connectedHostName
        self.pairingCode = pairingCode
        self.connectionError = nil
        self.activeTicket = nil
        self.activeRoute = nil
        self.remoteClient = nil
        self.connectionGeneration = UUID()
        self.pairingAttemptID = UUID()
        self.workspaceListRefreshTask = nil
    }

    isolated deinit {
        workspaceListRefreshTask?.cancel()
        if let remoteClient {
            Task { await remoteClient.disconnect() }
        }
    }

    /// Attach the facade after both objects exist. Called once from
    /// ``MobileShellComposite/init``.
    func bind(context: any MobileConnectionContext) {
        self.context = context
    }

    // MARK: - Pairing entry points

    func connectPreviewHost() {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            return
        }
        let attemptID = beginPairingAttempt()
        replaceRemoteClient(with: nil)
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        connectedHostName = PreviewMobileHost.hostName
        guard isCurrentPairingAttempt(attemptID) else { return }
        connectionState = .connected
        markMacConnectionHealthy()
        context?.ensurePreviewWorkspaceSelection()
    }

    func connectPairingInput() async {
        let trimmedCode = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            return
        }
        if trimmedCode.hasPrefix("cmux-ios://") {
            await connectPairingURL(trimmedCode)
            return
        }
        connectPreviewHost()
    }

    func connectManualHost(name: String, host: String, port: Int) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            connectionError = L10n.string("mobile.addDevice.invalidHost", defaultValue: "Enter a host or IP address, without spaces or URL paths.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }
        guard (1...65535).contains(port) else {
            connectionError = L10n.string("mobile.addDevice.invalidPort", defaultValue: "Enter a port from 1 to 65535.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }

        let directRoute = try? Self.manualHostRoute(host: normalizedHost, port: port)
        let attemptID = beginPairingAttempt()
        do {
            let ticket = try await manualHostTicket(
                name: trimmedName,
                host: normalizedHost,
                port: port
            )
            guard isCurrentPairingAttempt(attemptID) else { return }
            try await connect(ticket: ticket, allowsStackAuthFallback: true)
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return }
            mobileShellLog.error("manual host pairing failed: \(String(describing: error), privacy: .private)")
            // A definitive auth failure (expired/invalid token after the
            // refresh-then-retry in the RPC layer already gave up) must drive the
            // re-auth prompt, not the generic "could not connect / Retry" banner.
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return }
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute ?? directRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
        }
    }

    /// On launch (after StackAuth has bootstrapped), reconnect to the
    /// last-active paired Mac. Pulls (route, displayName, macDeviceID) from
    /// SQLite and re-mints an attach ticket via the StackAuth-authenticated
    /// manual host flow. Auth tokens never persist; we always re-mint.
    @discardableResult
    func reconnectActiveMacIfAvailable(stackUserID: String?) async -> Bool {
        guard let pairedMacStore else { return false }
        guard context?.isSignedIn == true else { return false }
        let saved: MobilePairedMac?
        do {
            saved = try await pairedMacStore.activeMac(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store activeMac failed: \(String(describing: error), privacy: .public)")
            return false
        }
        guard let mac = saved else { return false }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            mac.routes,
            supportedKinds: supportedKinds
        ) else { return false }
        await connectManualHost(name: mac.displayName ?? host, host: host, port: port)
        return connectionState == .connected
    }

    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind]
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        for route in routes.sorted(by: routeSortsBefore) {
            if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                continue
            }
            if case let .hostPort(host, port) = route.endpoint {
                return (host, port)
            }
        }
        return nil
    }

    @discardableResult
    func connectPairingURL(_ rawValue: String? = nil) async -> Bool {
        await connectPairingURLResult(rawValue).didConnect
    }

    @discardableResult
    func connectPairingURLResult(_ rawValue: String? = nil) async -> MobilePairingURLConnectionResult {
        let rawURL = Self.normalizedPairingURL(rawValue ?? pairingCode)
        let attemptID = beginPairingAttempt()
        let ticket: CmxAttachTicket
        do {
            ticket = try CmxAttachTicketInput.decode(rawURL)
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionError = L10n.string("mobile.pairing.invalidCode", defaultValue: "Invalid pairing code.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }

        do {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            try await connect(ticket: ticket)
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            return connectionState == .connected && activeTicket != nil ? .connected : .failed
        } catch is CancellationError {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        } catch {
            guard isCurrentPairingAttempt(attemptID) else { return .superseded }
            mobileShellLog.error("pairing failed: \(String(describing: error), privacy: .private)")
            // Surface a definitive auth failure as a re-auth prompt rather than a
            // generic connection error (matches the manual-host path).
            guard !disconnectForAuthorizationFailureIfNeeded(error) else { return .failed }
            connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return .failed
        }
    }

    func cancelPairing() {
        pairingAttemptID = UUID()
        connectionError = nil
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Disconnect from the currently paired Mac and forget it so the next
    /// session starts from a fresh QR scan. Clears in-memory state and the
    /// persisted active flag (other macs in SQLite stay, but none are marked
    /// active so reconnect-on-launch is a no-op until the user pairs again).
    func disconnectAndForgetActiveMac() {
        let staleMacID = activeTicket?.macDeviceID
        pairingAttemptID = UUID()
        connectionError = nil
        connectionRequiresReauth = false
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        if let pairedMacStore, let macID = staleMacID {
            // Fire-and-forget: forgetting the persisted mac is cleanup that must
            // not block the synchronous disconnect UI state update above.
            Task {
                do {
                    try await pairedMacStore.remove(macDeviceID: macID)
                } catch {
                    mobileShellLog.error("forgetActiveMac removal failed: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    /// Resets every piece of connection state on sign-out. The facade clears
    /// its own input/workspace state around this call.
    func resetForSignOut() {
        pairingAttemptID = UUID()
        connectionGeneration = UUID()
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        connectedHostName = ""
        pairingCode = ""
        connectionError = nil
        activeTicket = nil
        activeRoute = nil
        replaceRemoteClient(with: nil)
        context?.cancelRemoteOperationTasks()
    }

    /// Hard-disconnects with a user-facing error message (for example when
    /// the raw terminal input buffer overflows).
    func disconnect(showingError message: String) {
        connectionError = message
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    // MARK: - Ticket minting

    private static func normalizedPairingURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("cmux-ios://") else {
            return trimmed
        }
        let scalars = trimmed.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    private func manualHostTicket(name: String, host: String, port: Int) async throws -> CmxAttachTicket {
        let directRoute = try Self.manualHostRoute(host: host, port: port)
        let displayName = name.isEmpty ? host : name
        if MobileShellRouteAuthPolicy.routeAllowsStackAuth(directRoute) {
            do {
                let ticket = try await requestManualAttachTicket(
                    route: directRoute,
                    displayName: displayName
                )
                return ticket
            } catch {
                guard Self.shouldFallbackToSyntheticManualTicket(after: error) else {
                    throw error
                }
            }
            return try Self.manualHostTicket(
                displayName: displayName,
                macDeviceID: "manual-\(host):\(port)",
                route: directRoute
            )
        }
        return try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-\(host):\(port)",
            route: directRoute
        )
    }

    private static func shouldFallbackToSyntheticManualTicket(after error: any Error) -> Bool {
        guard case let MobileShellConnectionError.rpcError(code, message) = error else {
            return false
        }
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode,
           ["method_not_found", "not_found", "unknown_method", "unsupported_method"].contains(normalizedCode) {
            return true
        }
        return normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("method not found")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("ticket unavailable")
            || normalizedMessage.contains("ticket not available")
    }

    private static func manualHostTicket(
        displayName: String,
        macDeviceID: String,
        route: CmxAttachRoute
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: "manual-workspace",
            terminalID: nil,
            macDeviceID: macDeviceID,
            macDisplayName: displayName,
            routes: [route],
            expiresAt: Date().addingTimeInterval(60 * 60)
        )
    }

    private func requestManualAttachTicket(
        route: CmxAttachRoute,
        displayName: String
    ) async throws -> CmxAttachTicket {
        guard let runtime else {
            throw MobileShellConnectionError.insecureManualRoute
        }
        let probeTicket = try Self.manualHostTicket(
            displayName: displayName,
            macDeviceID: "manual-ticket-request",
            route: route
        )
        let client = MobileCoreRPCClient(
            runtime: runtime,
            route: route,
            ticket: probeTicket,
            allowsStackAuthFallback: true
        )
        let resultData = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.attach_ticket.create",
                params: [
                    "ttl_seconds": 3600,
                    "scope": "mac",
                ]
            ),
            timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
        )
        let response = try MobileManualAttachTicketCreateResponse.decode(resultData)
        return try response.ticket.constrainingRoutes(to: [route], fallbackDisplayName: displayName)
    }

    private func persistPairedMacFromTicket(_ ticket: CmxAttachTicket) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = identityProvider?.currentUserID
        do {
            try await pairedMacStore.upsert(
                macDeviceID: ticket.macDeviceID,
                displayName: ticket.macDisplayName,
                routes: ticket.routes,
                markActive: true,
                stackUserID: stackUserID
            )
        } catch {
            mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Connect

    private func connect(
        ticket: CmxAttachTicket,
        allowsStackAuthFallback: Bool? = nil
    ) async throws {
        let generation = UUID()
        connectionGeneration = generation
        context?.cancelRemoteOperationTasks()
        context?.clearRawTerminalInputBuffer()
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let supportedRoutes = Self.supportedRoutes(for: ticket, supportedKinds: supportedKinds)
        guard let firstRoute = supportedRoutes.first else {
            connectionError = L10n.string("mobile.pairing.unsupportedRoute", defaultValue: "This pairing code is not supported.")
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            return
        }
        guard Self.attachTicketIsUnexpired(ticket, now: runtime?.now() ?? Date()) else {
            connectionError = Self.localizedConnectionError(for: MobileShellConnectionError.attachTicketExpired, route: firstRoute)
            connectionState = .disconnected
            macConnectionStatus = .unavailable
            clearRemoteConnectionContext()
            throw MobileShellConnectionError.attachTicketExpired
        }

        activeTicket = ticket
        activeRoute = firstRoute
        connectedHostName = ticket.macDisplayName ?? ticket.macDeviceID
        replaceRemoteClient(with: nil)

        guard let runtime else {
            guard generation == connectionGeneration else { return }
            connectionError = nil
            context?.applyPreviewTicket(workspaceID: ticket.workspaceID, terminalID: ticket.terminalID)
            connectionState = .connected
            markMacConnectionHealthy()
            return
        }

        let workspaceListRequests = try Self.initialWorkspaceListRequests(for: ticket)
        // Stack auth is now the authorization gate for every request, so enable
        // it by default on any route trusted to carry the token (Tailscale,
        // loopback, LAN, .local). Untrusted manual public hosts stay off and
        // therefore cannot authorize, which is intended.
        let routeAllowsStackAuthFallback = allowsStackAuthFallback
            ?? supportedRoutes.allSatisfy(MobileShellRouteAuthPolicy.routeAllowsImplicitPairLinkStackAuth)
        var lastError: (any Error)?
        for route in supportedRoutes {
            activeRoute = route
            mobileShellLog.info("pairing trying route kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private)")
            let client = MobileCoreRPCClient(
                runtime: runtime,
                route: route,
                ticket: ticket,
                allowsStackAuthFallback: routeAllowsStackAuthFallback
            )
            for workspaceListRequest in workspaceListRequests {
                do {
                    let resultData = try await client.sendRequest(
                        workspaceListRequest.data,
                        timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
                    )
                    let response = try MobileSyncWorkspaceListResponse.decode(resultData)
                    guard generation == connectionGeneration, context?.isSignedIn == true else { return }
                    replaceRemoteClient(with: client)
                    context?.connectionDidEstablish()
                    connectionError = nil
                    await persistPairedMacFromTicket(ticket)
                    context?.applyRemoteWorkspaceList(
                        response,
                        preferActiveTicketTarget: workspaceListRequest.preferActiveTicketTarget,
                        mergeExistingWorkspaces: false
                    )
                    context?.syncSelectedTerminalForWorkspace()
                    connectionState = .connected
                    markMacConnectionHealthy()
                    if workspaceListRequest.isScoped {
                        scheduleFullWorkspaceListRefreshIfAvailable(
                            client: client,
                            route: route,
                            generation: generation
                        )
                    }
                    return
                } catch {
                    lastError = error
                    guard generation == connectionGeneration, context?.isSignedIn == true else { return }
                    mobileShellLog.error(
                        "pairing route failed kind=\(route.kind.rawValue, privacy: .public) endpoint=\(route.endpoint.logDescription, privacy: .private) scoped=\(workspaceListRequest.isScoped ? 1 : 0, privacy: .public): \(String(describing: error), privacy: .private)"
                    )
                }
            }
        }

        clearRemoteConnectionContext()
        throw lastError ?? MobileShellConnectionError.connectionClosed
    }

    private struct WorkspaceListRequest {
        var data: Data
        var isScoped: Bool
        var preferActiveTicketTarget: Bool
    }

    private static func supportedRoutes(
        for ticket: CmxAttachTicket,
        supportedKinds: [CmxAttachTransportKind]
    ) -> [CmxAttachRoute] {
        let orderedRoutes = ticket.routes.sorted(by: routeSortsBefore)
        guard !supportedKinds.isEmpty else {
            return orderedRoutes
        }
        let supportedKinds = Set(supportedKinds)
        return orderedRoutes.filter { route in
            supportedKinds.contains(route.kind)
        }
    }

    private static func attachTicketIsUnexpired(_ ticket: CmxAttachTicket, now: Date) -> Bool {
        ticket.expiresAt > now
    }

    private static func initialWorkspaceListParams(for ticket: CmxAttachTicket) -> [String: Any] {
        guard UUID(uuidString: ticket.workspaceID) != nil else {
            return [:]
        }
        var params: [String: Any] = ["workspace_id": ticket.workspaceID]
        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            params["terminal_id"] = terminalID
        }
        return params
    }

    private static func initialWorkspaceListRequests(for ticket: CmxAttachTicket) throws -> [WorkspaceListRequest] {
        let scopedParams = initialWorkspaceListParams(for: ticket)
        let hasAttachToken = ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        var requests: [WorkspaceListRequest] = []
        if hasAttachToken {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }

        if !scopedParams.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: scopedParams),
                    isScoped: !scopedParams.isEmpty,
                    preferActiveTicketTarget: true
                )
            )
        }

        if requests.isEmpty {
            requests.append(
                WorkspaceListRequest(
                    data: try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:]),
                    isScoped: false,
                    preferActiveTicketTarget: true
                )
            )
        }
        return requests
    }

    // MARK: - Workspace list refresh

    private func scheduleFullWorkspaceListRefreshIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID
    ) {
        guard workspaceListRefreshTask == nil else { return }
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.workspaceListRefreshTask = nil }
            _ = await self.refreshAllWorkspacesWithAttachTokenIfAvailable(
                client: client,
                route: route,
                generation: generation,
                timeoutNanoseconds: self.runtime?.rpcRequestTimeoutNanoseconds
            )
        }
    }

    private func refreshAllWorkspacesWithAttachTokenIfAvailable(
        client: MobileCoreRPCClient,
        route: CmxAttachRoute,
        generation: UUID,
        timeoutNanoseconds: UInt64? = nil
    ) async -> Bool {
        guard MobileShellRouteAuthPolicy.routeAllowsStackAuth(route),
              let attachToken = activeTicket?.authToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !attachToken.isEmpty else {
            return false
        }
        do {
            let resultData = try await client.sendRequest(
                MobileCoreRPCClient.requestData(
                    method: "workspace.list",
                    params: [:]
                ),
                timeoutNanoseconds: timeoutNanoseconds ?? runtime?.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            guard isCurrentRemoteConnection(client: client, generation: generation) else {
                return false
            }
            let activeTicketWorkspaceID = activeTicket.map { MobileWorkspacePreview.ID(rawValue: $0.workspaceID) }
            let selectedWorkspaceID = context?.selectedWorkspaceID
            context?.applyRemoteWorkspaceList(
                response,
                preferActiveTicketTarget: selectedWorkspaceID == nil || selectedWorkspaceID == activeTicketWorkspaceID,
                mergeExistingWorkspaces: false
            )
            return true
        } catch {
            mobileShellLog.info("full mobile workspace list unavailable after scoped attach: \(String(describing: error), privacy: .private)")
            if isCurrentRemoteConnection(client: client, generation: generation) {
                _ = disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
    }

    /// Refreshes the workspace list in response to a `workspace.updated` push
    /// event or an event-stream restart.
    func scheduleWorkspaceListRefreshFromEvent() {
        guard let client = remoteClient else { return }
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = Task { @MainActor [weak self] in
            defer { self?.workspaceListRefreshTask = nil }
            guard let self else { return }
            do {
                let request = try MobileCoreRPCClient.requestData(method: "mobile.workspace.list", params: [:])
                let data = try await client.sendRequest(request)
                let response = try MobileSyncWorkspaceListResponse.decode(data)
                guard self.remoteClient === client, self.connectionState == .connected else { return }
                self.context?.applyRemoteWorkspaceList(
                    response,
                    preferActiveTicketTarget: false,
                    mergeExistingWorkspaces: false
                )
                self.context?.syncSelectedTerminalForWorkspace()
            } catch {
                mobileShellLog.error("workspace list event refresh failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Cancels an in-flight workspace-list refresh. Part of the facade's
    /// `cancelRemoteOperationTasks` teardown.
    func cancelWorkspaceListRefresh() {
        workspaceListRefreshTask?.cancel()
        workspaceListRefreshTask = nil
    }

    // MARK: - Teardown + generation guards

    private func clearActiveConnectionContext() {
        activeTicket = nil
        activeRoute = nil
        connectedHostName = ""
    }

    private func clearRemoteConnectionContext() {
        connectionGeneration = UUID()
        context?.cancelRemoteOperationTasks()
        clearActiveConnectionContext()
        macConnectionStatus = .unavailable
        replaceRemoteClient(with: nil)
        context?.clearRawTerminalInputBuffer()
    }

    /// Set `remoteClient` to a new value (possibly nil) and disconnect the
    /// previous one so we don't leak a persistent transport.
    private func replaceRemoteClient(with newValue: MobileCoreRPCClient?) {
        let previous = remoteClient
        remoteClient = newValue
        if let previous, previous !== newValue {
            Task { await previous.disconnect() }
        }
    }

    private func beginPairingAttempt() -> UUID {
        let attemptID = UUID()
        pairingAttemptID = attemptID
        connectionGeneration = UUID()
        context?.cancelRemoteOperationTasks()
        context?.clearRawTerminalInputBuffer()
        connectionError = nil
        return attemptID
    }

    private func isCurrentPairingAttempt(_ attemptID: UUID) -> Bool {
        pairingAttemptID == attemptID && context?.isSignedIn == true
    }

    /// Whether a response belongs to the current connection AND the shell is
    /// still showing it (used by remote create/input operations).
    func isCurrentRemoteOperation(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        isCurrentRemoteConnection(client: client, generation: generation)
            && connectionState == .connected
    }

    /// Whether a response belongs to the current connection generation,
    /// client identity, and signed-in session.
    func isCurrentRemoteConnection(client: MobileCoreRPCClient, generation: UUID) -> Bool {
        generation == connectionGeneration
            && client === remoteClient
            && context?.isSignedIn == true
    }

    // MARK: - Connection health

    func markMacConnectionHealthy() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .connected
        recovery.isRecoveringConnection = false
        recovery.connectionRecoveryFailed = false
        connectionRequiresReauth = false
    }

    func markMacConnectionReconnecting() {
        guard connectionState == .connected, remoteClient != nil else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .reconnecting
        recovery.isRecoveringConnection = true
        recovery.connectionRecoveryFailed = false
    }

    func markMacConnectionUnavailable() {
        guard connectionState == .connected else {
            macConnectionStatus = .unavailable
            return
        }
        macConnectionStatus = .unavailable
        recovery.isRecoveringConnection = false
        recovery.connectionRecoveryFailed = true
    }

    func markMacConnectionUnavailableIfNeeded(after error: any Error) {
        guard Self.isMacAvailabilityFailure(error) else { return }
        markMacConnectionUnavailable()
    }

    private static func isMacAvailabilityFailure(_ error: any Error) -> Bool {
        if error is CmxNetworkByteTransportError {
            return true
        }
        guard let shellError = error as? MobileShellConnectionError else {
            return false
        }
        switch shellError {
        case .connectionClosed, .requestTimedOut:
            return true
        case .invalidResponse, .insecureManualRoute, .attachTicketExpired, .authorizationFailed, .accountMismatch, .rpcError:
            // .accountMismatch means the Mac is reachable but signed in to a
            // different account; that is an auth problem, not a Mac-availability one.
            return false
        }
    }

    // MARK: - Error handling

    @discardableResult
    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
        connectionRequiresReauth = true
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        return true
    }

    /// Surfaces a remote-operation failure as a localized connection error.
    func reportConnectionError(_ error: any Error) {
        connectionError = Self.localizedConnectionError(for: error)
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut:
            return false
        }
    }

    private static func localizedConnectionError(for error: any Error, route: CmxAttachRoute? = nil) -> String {
        let hostPort = route.flatMap(Self.hostPortDescription(for:))
        if let networkError = error as? CmxNetworkByteTransportError {
            switch networkError {
            case .connectionTimedOut:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectTimedOutFormat",
                    defaultValue: "No response from %@:%d. Your Mac may be asleep or off Tailscale. Make sure it's awake and on the same Tailscale network.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case let .connectionFailed(_, kind):
                switch kind {
                case .connectionRefused:
                    return L10n.string(
                        "mobile.pairing.appNotRunning",
                        defaultValue: "Your Mac is reachable, but cmux isn't running there (or mobile pairing is off). Open cmux on the Mac, then try again."
                    )
                case .permissionDenied:
                    return L10n.string(
                        "mobile.pairing.localNetworkPermission",
                        defaultValue: "iOS blocked the connection. Allow cmux to use the Local Network in iOS Settings, then try again."
                    )
                case .hostUnreachable:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.hostUnreachableFormat",
                        defaultValue: "Can't reach %@:%d. Make sure your Mac is awake and on the same Tailscale network as this device.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .dnsFailed:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.dnsFailedFormat",
                        defaultValue: "Couldn't resolve %@. Check that Tailscale is connected on both devices.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .timedOut, .secureChannelFailed, .generic:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.connectionFailedFormat",
                        defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                }
            case .notConnected, .alreadyClosed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionFailedFormat",
                    defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .receiveFailed, .sendFailed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionDroppedFormat",
                    defaultValue: "Connected to %@:%d, but the host closed the connection. Check that the host app is still running.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .emptyHost, .invalidPort, .invalidMaximumReceiveLength, .unsupportedRouteKind, .unsupportedEndpoint, .receiveAlreadyInProgress, .sendAlreadyInProgress:
                break
            }
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
        switch connectionError {
        case .requestTimedOut:
            return localizedHostPortConnectionError(
                key: "mobile.pairing.connectionTimedOutFormat",
                defaultValue: "No response from %@:%d. Make sure the host app is open and accepting mobile connections.",
                fallbackKey: "mobile.pairing.requestTimedOut",
                fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                hostPort: hostPort
            )
        case .insecureManualRoute:
            return L10n.string("mobile.pairing.secureRouteRequired", defaultValue: "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
        case .attachTicketExpired:
            return L10n.string("mobile.pairing.attachTicketExpired", defaultValue: "This pairing link expired. Pair again with a fresh QR/link from that computer.")
        case .authorizationFailed:
            return L10n.string("mobile.pairing.authorizationFailed", defaultValue: "Sign in on your computer with the same account, or pair with a QR/link from that computer.")
        case .accountMismatch:
            return L10n.string("mobile.pairing.accountMismatch", defaultValue: "This Mac is signed in to a different cmux account. Sign out and sign back in with the account that owns this Mac.")
        case .invalidResponse, .connectionClosed, .rpcError:
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
    }

    private static func localizedHostPortConnectionError(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        fallbackKey: StaticString,
        fallbackDefaultValue: String.LocalizationValue,
        hostPort: (host: String, port: Int)?
    ) -> String {
        guard let hostPort else {
            return L10n.string(fallbackKey, defaultValue: fallbackDefaultValue)
        }
        return String(
            format: L10n.string(key, defaultValue: defaultValue),
            hostPort.host,
            hostPort.port
        )
    }

    private static func hostPortDescription(for route: CmxAttachRoute) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return (host, port)
    }

    private static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }
}

/// Wire shape of the `mobile.attach_ticket.create` RPC result.
private struct MobileManualAttachTicketCreateResponse: Decodable, Sendable {
    var ticket: CmxAttachTicket

    static func decode(_ data: Data) throws -> MobileManualAttachTicketCreateResponse {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileManualAttachTicketCreateResponse.self, from: data)
    }
}

private extension CmxAttachTicket {
    /// A copy of the ticket constrained to the routes the client actually
    /// dialed, with a display-name fallback for hosts that omit one.
    func constrainingRoutes(
        to routes: [CmxAttachRoute],
        fallbackDisplayName: String
    ) throws -> CmxAttachTicket {
        try CmxAttachTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            macDeviceID: macDeviceID,
            macDisplayName: macDisplayName ?? fallbackDisplayName,
            routes: routes,
            expiresAt: expiresAt,
            authToken: authToken
        )
    }
}
