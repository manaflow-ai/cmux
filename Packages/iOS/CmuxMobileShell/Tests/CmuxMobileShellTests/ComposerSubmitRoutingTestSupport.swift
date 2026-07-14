import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

// Scripted host fixtures for the composer send-routing tests
// (ComposerSubmitRoutingTests.swift): a connected store backed by a recording
// router that captures which terminal each terminal.paste / terminal.paste_image
// request targeted, and can be told to reject paste_image so the keep-on-failure
// path is exercised over the real wire.

// MARK: - Runtime double

struct RoutingTestRuntime: MobileSyncRuntime {
    var transportFactory: any CmxByteTransportFactory
    var stackAccessTokenProvider: @Sendable () async throws -> String = { "test-stack-token" }
    var stackAccessTokenForceRefresher: @Sendable () async throws -> String = { "test-stack-token" }
    var rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var now: @Sendable () -> Date = { Date() }
    var supportedRouteKinds: [CmxAttachTransportKind] = [.debugLoopback]
    var pairingRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    var supportsServerPushEvents: Bool = true
    var livenessProbeTimeoutNanoseconds: UInt64 = 200_000_000
}

// MARK: - Recording host (router + transport)

/// Answers the connect-time handshake for a workspace with TWO terminals and
/// records every terminal.paste / terminal.paste_image request's target
/// surface_id (and the image format), in send order. Can be configured to reject
/// the paste_image call so the composer's keep-on-failure path runs.
actor RoutingHostRouter {
    nonisolated let workspaceListGate = WorkspaceListRequestGate()
    struct PasteImageRecord: Sendable {
        var surfaceID: String
        var format: String
    }
    struct PasteRecord: Sendable {
        var surfaceID: String
        var text: String
    }
    private(set) var pasteImages: [PasteImageRecord] = []
    private(set) var pastes: [PasteRecord] = []
    private(set) var dismisses: [(notificationIDs: [String], clientID: String?)] = []
    private var workspaceCreateGroupIDs: [String?] = []
    /// Reject the Nth (0-based) and later paste_image requests; `nil` accepts all.
    private var rejectPasteImageFromIndex: Int?
    private var holdFirstPasteImage = false
    private var firstPasteImageHeld = false
    private var firstPasteImageContinuation: CheckedContinuation<Void, Never>?
    private var firstPasteImageReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var workspaceCreateCount = 0
    private var workspaceHasBeenCreated = false
    private var terminalHasBeenCreated = false
    private var selectedHostWorkspaceID = "ws-route"
    private var rejectWorkspaceCreate = false
    private var rejectWorkspaceList = false
    private var terminalCloseErrorCode: String?
    private var dropTerminalCloseResponse = false
    private var terminalCloseCount = 0
    private var usesNilPaneIDCloseFallbackFixture = false
    private var closedTerminalIDs: Set<String> = []
    private var terminalReorderCount = 0
    private var terminalCloseReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdFirstWorkspaceCreate = false
    private var firstWorkspaceCreateHeld = false
    private var firstWorkspaceCreateContinuation: CheckedContinuation<Void, Never>?
    private var firstWorkspaceCreateReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdFirstTerminalCreate = false
    private var firstTerminalCreateHeld = false
    private var terminalCreateCount = 0
    private var heldTerminalCreateCount = 0
    private var terminalCreateContinuations: [CheckedContinuation<Void, Never>] = []
    private var firstTerminalCreateReachedWaiters: [CheckedContinuation<Void, Never>] = []

    static let workspaceID = "ws-route"
    static let terminalA = "term-route-a"
    static let terminalB = "term-route-b"

    /// Reject every terminal.paste_image with an error frame, modeling a host
    /// that cannot accept the image (the composer must keep the attachment).
    func setRejectPasteImage(_ reject: Bool) {
        rejectPasteImageFromIndex = reject ? 0 : nil
    }

    /// Accept paste_image requests before `index` (0-based) and reject that one
    /// and all later ones, so a test can prove a partial failure clears only the
    /// acknowledged attachments.
    func rejectPasteImage(fromIndex index: Int) {
        rejectPasteImageFromIndex = index
    }

    /// Park the FIRST paste_image response until ``releaseFirstPasteImage()``,
    /// so a test can switch the selected terminal while that send is in flight
    /// and prove the send still targets the captured terminal.
    func setHoldFirstPasteImage(_ hold: Bool) {
        holdFirstPasteImage = hold
    }

    /// Resolve when the first paste_image request has arrived (and is parked).
    func awaitFirstPasteImageReached() async {
        if firstPasteImageHeld { return }
        await withCheckedContinuation { firstPasteImageReachedWaiters.append($0) }
    }

    /// Release the parked first paste_image so its (success) response is sent.
    func releaseFirstPasteImage() {
        let continuation = firstPasteImageContinuation
        firstPasteImageContinuation = nil
        continuation?.resume()
    }

    func setRejectWorkspaceCreate(_ reject: Bool) {
        rejectWorkspaceCreate = reject
    }

    func setRejectWorkspaceList(_ reject: Bool) {
        rejectWorkspaceList = reject
    }

    func setTerminalCloseErrorCode(_ code: String?) {
        terminalCloseErrorCode = code
    }

    func setDropTerminalCloseResponse(_ drop: Bool) {
        dropTerminalCloseResponse = drop
    }

    func setUsesNilPaneIDCloseFallbackFixture(_ enabled: Bool) {
        usesNilPaneIDCloseFallbackFixture = enabled
    }

    func awaitTerminalCloseReached() async {
        if terminalCloseCount > 0 { return }
        await withCheckedContinuation { terminalCloseReachedWaiters.append($0) }
    }

    func setHoldFirstWorkspaceCreate(_ hold: Bool) {
        holdFirstWorkspaceCreate = hold
    }

    func awaitFirstWorkspaceCreateReached() async {
        if firstWorkspaceCreateHeld { return }
        await withCheckedContinuation { firstWorkspaceCreateReachedWaiters.append($0) }
    }

    func releaseFirstWorkspaceCreate() {
        let continuation = firstWorkspaceCreateContinuation
        firstWorkspaceCreateContinuation = nil
        continuation?.resume()
    }

    func setHoldFirstTerminalCreate(_ hold: Bool) {
        holdFirstTerminalCreate = hold
    }

    func awaitFirstTerminalCreateReached() async {
        if firstTerminalCreateHeld { return }
        await withCheckedContinuation { firstTerminalCreateReachedWaiters.append($0) }
    }

    func releaseFirstTerminalCreate() {
        guard !terminalCreateContinuations.isEmpty else { return }
        terminalCreateContinuations.removeFirst().resume()
    }

    func recordedWorkspaceCreateCount() -> Int { workspaceCreateCount }
    func recordedWorkspaceCreateGroupIDs() -> [String?] { workspaceCreateGroupIDs }
    func recordedTerminalCloseCount() -> Int { terminalCloseCount }
    func recordedTerminalReorderCount() -> Int { terminalReorderCount }
    func recordedTerminalCreateCount() -> Int { terminalCreateCount }
    func recordedHeldTerminalCreateCount() -> Int { heldTerminalCreateCount }

    func recordedPasteImages() -> [PasteImageRecord] { pasteImages }
    func recordedPastes() -> [PasteRecord] { pastes }
    func recordedDismisses() -> [(notificationIDs: [String], clientID: String?)] { dismisses }

    /// Sendable extract of the request fields the router needs, pulled off the
    /// non-Sendable params dictionary before crossing the Task boundary.
    struct RequestInfo: Sendable {
        var method: String?
        var id: String?
        var surfaceID: String?
        var imageFormat: String?
        var text: String?
        var notificationIDs: [String]?
        var clientID: String?
        var groupID: String?
        var workspaceID: String?
    }

    func response(_ info: RequestInfo) async -> Data? {
        let method = info.method
        let id = info.id
        switch method {
        case "workspace.list", "mobile.workspace.list":
            let workspaceTitle = await workspaceListGate.beforeResponse() ?? "Routing Workspace"
            if rejectWorkspaceList {
                return try? Self.errorFrame(id: id, message: "workspace.list rejected")
            }
            let routingWorkspace = usesNilPaneIDCloseFallbackFixture
                ? Self.nilPaneIDCloseFallbackWorkspacePayload(
                    title: workspaceTitle,
                    closedTerminalIDs: closedTerminalIDs
                )
                : Self.routingWorkspacePayload(
                    title: workspaceTitle,
                    isSelected: selectedHostWorkspaceID == Self.workspaceID,
                    includesCreatedTerminal: terminalHasBeenCreated
                )
            var workspaces: [[String: Any]] = [routingWorkspace]
            if workspaceHasBeenCreated {
                workspaces.append(Self.createdWorkspacePayload(
                    isSelected: selectedHostWorkspaceID == "workspace-created"
                ))
            }
            return try? Self.resultFrame(id: id, result: [
                "workspaces": workspaces,
            ])
        case "mobile.host.status":
            return try? Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": [
                    "events.v1",
                    "terminal.render_grid.v1",
                    "terminal.replay.v1",
                    "workspace.group_actions.v1",
                ],
            ])
        case "mobile.events.subscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": false,
            ])
        case "workspace.create":
            workspaceCreateCount += 1
            workspaceCreateGroupIDs.append(info.groupID)
            if !rejectWorkspaceCreate {
                workspaceHasBeenCreated = true
                selectedHostWorkspaceID = "workspace-created"
            }
            if workspaceCreateCount == 1 && holdFirstWorkspaceCreate {
                firstWorkspaceCreateHeld = true
                let reachedWaiters = firstWorkspaceCreateReachedWaiters
                firstWorkspaceCreateReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { firstWorkspaceCreateContinuation = $0 }
            }
            if rejectWorkspaceCreate {
                return try? Self.errorFrame(id: id, message: "workspace.create rejected")
            }
            return try? Self.resultFrame(id: id, result: [
                "workspaces": [
                    [
                        "id": Self.workspaceID,
                        "title": "Routing Workspace",
                        "is_selected": false,
                        "terminals": [],
                    ],
                    Self.createdWorkspacePayload(isSelected: true),
                ],
                "created_workspace_id": "workspace-created",
                "created_terminal_id": "terminal-created",
            ])
        case "terminal.create":
            terminalCreateCount += 1
            terminalHasBeenCreated = true
            selectedHostWorkspaceID = info.workspaceID ?? Self.workspaceID
            if terminalCreateCount == 1 && holdFirstTerminalCreate {
                heldTerminalCreateCount += 1
                firstTerminalCreateHeld = true
                let reachedWaiters = firstTerminalCreateReachedWaiters
                firstTerminalCreateReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { terminalCreateContinuations.append($0) }
            }
            var workspaces: [[String: Any]] = [Self.routingWorkspacePayload(
                title: "Terminal Response Workspace",
                isSelected: true,
                includesCreatedTerminal: true
            )]
            if workspaceHasBeenCreated {
                workspaces.append(Self.createdWorkspacePayload(isSelected: false))
            }
            return try? Self.resultFrame(id: id, result: [
                "workspaces": workspaces,
                "created_terminal_id": "terminal-route-created",
            ])
        case "terminal.close":
            terminalCloseCount += 1
            let reachedWaiters = terminalCloseReachedWaiters
            terminalCloseReachedWaiters = []
            for waiter in reachedWaiters { waiter.resume() }
            if dropTerminalCloseResponse { return nil }
            if let terminalCloseErrorCode {
                return try? Self.errorFrame(
                    id: id,
                    code: terminalCloseErrorCode,
                    message: "terminal.close rejected"
                )
            }
            if let surfaceID = info.surfaceID {
                closedTerminalIDs.insert(surfaceID)
            }
            return try? Self.resultFrame(id: id, result: [:])
        case "terminal.reorder":
            terminalReorderCount += 1
            return try? Self.resultFrame(id: id, result: [:])
        case "terminal.paste_image":
            let surfaceID = info.surfaceID ?? ""
            let format = info.imageFormat ?? ""
            let index = pasteImages.count
            pasteImages.append(PasteImageRecord(surfaceID: surfaceID, format: format))
            if index == 0 && holdFirstPasteImage {
                firstPasteImageHeld = true
                let reachedWaiters = firstPasteImageReachedWaiters
                firstPasteImageReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { firstPasteImageContinuation = $0 }
            }
            if let rejectFrom = rejectPasteImageFromIndex, index >= rejectFrom {
                return try? Self.errorFrame(id: id, message: "paste_image rejected")
            }
            return try? Self.resultFrame(id: id, result: [:])
        case "terminal.paste":
            let surfaceID = info.surfaceID ?? ""
            let text = info.text ?? ""
            pastes.append(PasteRecord(surfaceID: surfaceID, text: text))
            return try? Self.resultFrame(id: id, result: [:])
        case "notification.dismiss":
            dismisses.append((
                notificationIDs: info.notificationIDs ?? [],
                clientID: info.clientID
            ))
            return try? Self.resultFrame(id: id, result: [:])
        case "mobile.events.unsubscribe", "mobile.terminal.replay", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

}

// MARK: - Connected-store builder

/// Build a store with a workspace of two terminals (term-a selected) and a real
/// `MobileCoreRPCClient` wired DIRECTLY onto the store, backed by the recording
/// transport. This deliberately bypasses the pairing/connect handshake (which
/// the scripted-host harness cannot complete in this environment): the composer
/// send path only needs a live `remoteClient` to reach the wire, and the
/// session connects its transport lazily on the first request. The result is a
/// deterministic end-to-end exercise of submitComposer's routing over the real
/// terminal.paste / terminal.paste_image RPC frames.
@MainActor
func makeRoutingConnectedStore(
    router: RoutingHostRouter,
    pendingDismissQueue: PendingNotificationDismissQueue = PendingNotificationDismissQueue(
        defaults: UserDefaults(suiteName: "routing-dismiss-\(UUID().uuidString)")!
    ),
    macScopedWorkspaceMutations: Bool = false,
    connectionState: MobileConnectionState = .disconnected,
    rpcRequestTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000,
    workspaceActionCapabilities: MobileWorkspaceActionCapabilities = .none
) async throws -> MobileShellComposite {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router),
        rpcRequestTimeoutNanoseconds: rpcRequestTimeoutNanoseconds
    )
    let terminals = [
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
    ]
    var workspace = MobileWorkspacePreview(
        id: .init(rawValue: RoutingHostRouter.workspaceID),
        name: "Routing Workspace",
        terminals: terminals
    )
    workspace.actionCapabilities = workspaceActionCapabilities
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        connectionState: connectionState,
        workspaces: [workspace],
        pendingDismissQueue: pendingDismissQueue
    )
    // 127.0.0.1 is a Stack-auth-trusted route, so authorized requests carry the
    // Stack token and do not throw insecureManualRoute before reaching the
    // transport. Enable the fallback to match the trusted-route production path.
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56585)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: macScopedWorkspaceMutations ? "" : RoutingHostRouter.workspaceID,
        terminalID: macScopedWorkspaceMutations ? nil : RoutingHostRouter.terminalA,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600),
        authToken: macScopedWorkspaceMutations ? "ticket-secret" : nil
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    workspace.macDeviceID = "test-mac"
    store.setWorkspaceStatesForTesting(
        [
            "test-mac": MacWorkspaceState(
                macDeviceID: "test-mac",
                displayName: "Test Mac",
                workspaces: [workspace],
                status: .connected,
                actionCapabilities: workspaceActionCapabilities
            ),
        ],
        foregroundMacDeviceID: "test-mac"
    )
    return store
}

/// Install a fresh `remoteClient` on an already-built store, backed by `router`.
/// Models the new transport a reconnect / account switch / Mac switch installs:
/// the mid-submit identity guard must abort BEFORE any further image or the text
/// reaches this second router, so a test can assert that router recorded nothing.
@MainActor
func installFreshRemoteClient(on store: MobileShellComposite, router: RoutingHostRouter) throws {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56586)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: RoutingHostRouter.workspaceID,
        terminalID: RoutingHostRouter.terminalA,
        macDeviceID: "test-mac-2",
        macDisplayName: "Test Mac 2",
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600)
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    store.foregroundMacDeviceID = "test-mac-2"
}

/// Install a live read-only secondary client on `store`, backed by `router`.
@MainActor
func installSecondaryClient(
    on store: MobileShellComposite,
    macDeviceID: String,
    router: RoutingHostRouter
) throws {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let route = try CmxAttachRoute(
        id: "debug_loopback_\(macDeviceID)",
        kind: .debugLoopback,
        endpoint: .hostPort(host: "127.0.0.1", port: 56587)
    )
    let ticket = try CmxAttachTicket(
        workspaceID: RoutingHostRouter.workspaceID,
        terminalID: RoutingHostRouter.terminalA,
        macDeviceID: macDeviceID,
        macDisplayName: macDeviceID,
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600)
    )
    let client = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    store.secondaryMacSubscriptions[macDeviceID] = SecondaryMacSubscription(
        macDeviceID: macDeviceID,
        client: client,
        route: route,
        ticket: ticket,
        supportedHostCapabilities: [],
        actionCapabilities: .none
    )
}
