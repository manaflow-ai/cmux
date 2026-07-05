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

private struct RoutingTestRuntime: MobileSyncRuntime {
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
    private(set) var inputs: [RoutingHostInputRecord] = []
    private(set) var dismisses: [(notificationIDs: [String], clientID: String?)] = []
    /// Reject the Nth (0-based) and later paste_image requests; `nil` accepts all.
    private var rejectPasteImageFromIndex: Int?
    private var holdFirstPasteImage = false
    private var firstPasteImageHeld = false
    private var firstPasteImageContinuation: CheckedContinuation<Void, Never>?
    private var firstPasteImageReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdFirstTerminalInput = false
    private var terminalInputArrivalCount = 0
    private var firstTerminalInputHeld = false
    private var firstTerminalInputContinuation: CheckedContinuation<Void, Never>?
    private var firstTerminalInputReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var inputCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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

    /// Park the first terminal.input request before recording it, modeling a host
    /// whose first PTY write is still in progress while later input is submitted.
    func setHoldFirstTerminalInput(_ hold: Bool) {
        holdFirstTerminalInput = hold
    }

    /// Resolve when the first paste_image request has arrived (and is parked).
    func awaitFirstPasteImageReached() async {
        if firstPasteImageHeld { return }
        await withCheckedContinuation { firstPasteImageReachedWaiters.append($0) }
    }

    /// Resolve when the first terminal.input request has arrived (and is parked).
    func awaitFirstTerminalInputReached() async {
        if firstTerminalInputHeld { return }
        await withCheckedContinuation { firstTerminalInputReachedWaiters.append($0) }
    }

    /// Release the parked first paste_image so its (success) response is sent.
    func releaseFirstPasteImage() {
        let continuation = firstPasteImageContinuation
        firstPasteImageContinuation = nil
        continuation?.resume()
    }

    /// Release the parked first terminal.input so its (success) response is sent.
    func releaseFirstTerminalInput() {
        let continuation = firstTerminalInputContinuation
        firstTerminalInputContinuation = nil
        continuation?.resume()
    }

    /// Resolve once at least `count` terminal.input requests have been applied.
    func awaitRecordedInputCount(_ count: Int) async {
        if inputs.count >= count { return }
        await withCheckedContinuation { continuation in
            inputCountWaiters.append((count: count, continuation: continuation))
        }
    }

    func recordedPasteImages() -> [PasteImageRecord] { pasteImages }
    func recordedPastes() -> [PasteRecord] { pastes }
    func recordedInputs() -> [RoutingHostInputRecord] { inputs }
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
    }

    func response(_ info: RequestInfo) async -> Data? {
        let method = info.method
        let id = info.id
        switch method {
        case "workspace.list", "mobile.workspace.list":
            return try? Self.resultFrame(id: id, result: [
                "workspaces": [
                    [
                        "id": Self.workspaceID,
                        "title": "Routing Workspace",
                        "current_directory": "/tmp/route",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": Self.terminalA,
                                "title": "A",
                                "current_directory": "/tmp/route",
                                "is_ready": true,
                                "is_focused": true,
                            ],
                            [
                                "id": Self.terminalB,
                                "title": "B",
                                "current_directory": "/tmp/route",
                                "is_ready": true,
                                "is_focused": false,
                            ],
                        ],
                    ],
                ],
            ])
        case "mobile.host.status":
            return try? Self.resultFrame(id: id, result: [
                "terminal_fidelity": "render_grid",
                "capabilities": ["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"],
            ])
        case "mobile.events.subscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": false,
            ])
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
        case "terminal.input":
            let surfaceID = info.surfaceID ?? ""
            let text = info.text ?? ""
            terminalInputArrivalCount += 1
            if terminalInputArrivalCount == 1, holdFirstTerminalInput {
                firstTerminalInputHeld = true
                let reachedWaiters = firstTerminalInputReachedWaiters
                firstTerminalInputReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { firstTerminalInputContinuation = $0 }
            }
            inputs.append(RoutingHostInputRecord(surfaceID: surfaceID, text: text))
            resumeSatisfiedInputCountWaiters()
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

    private static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private static func errorFrame(id: String?, message: String) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": ["message": message],
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    private func resumeSatisfiedInputCountWaiters() {
        var remaining: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in inputCountWaiters {
            if inputs.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        inputCountWaiters = remaining
    }
}

private struct RoutingTransportFactory: CmxByteTransportFactory {
    let router: RoutingHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        RoutingTransport(router: router)
    }
}

private actor RoutingTransport: CmxByteTransport {
    private let router: RoutingHostRouter
    private var pendingFrames: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var isClosed = false

    init(router: RoutingHostRouter) {
        self.router = router
    }

    func connect() async throws {}

    func receive() async throws -> Data? {
        if !pendingFrames.isEmpty {
            return pendingFrames.removeFirst()
        }
        if isClosed {
            return nil
        }
        return await withCheckedContinuation { continuation in
            receiveWaiters.append(continuation)
        }
    }

    func send(_ data: Data) async throws {
        var buffer = data
        let payloads = try MobileSyncFrameCodec.decodeFrames(from: &buffer)
        for payload in payloads {
            let parsed = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let params = parsed?["params"] as? [String: Any]
            // Extract only the Sendable fields the router needs BEFORE the Task,
            // so the non-Sendable params dictionary never crosses the boundary.
            let info = RoutingHostRouter.RequestInfo(
                method: parsed?["method"] as? String,
                id: parsed?["id"] as? String,
                surfaceID: params?["surface_id"] as? String,
                imageFormat: params?["image_format"] as? String,
                text: params?["text"] as? String,
                notificationIDs: params?["notification_ids"] as? [String],
                clientID: params?["client_id"] as? String
            )
            Task { [router, weak self] in
                guard let response = await router.response(info) else {
                    return
                }
                await self?.deliver(response)
            }
        }
    }

    func close() async {
        isClosed = true
        let waiters = receiveWaiters
        receiveWaiters = []
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
    }

    private func deliver(_ frame: Data) {
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
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
    )
) async throws -> MobileShellComposite {
    let runtime = RoutingTestRuntime(
        transportFactory: RoutingTransportFactory(router: router)
    )
    let terminals = [
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalA), name: "A"),
        MobileTerminalPreview(id: .init(rawValue: RoutingHostRouter.terminalB), name: "B"),
    ]
    let store = MobileShellComposite(
        runtime: runtime,
        isSignedIn: true,
        workspaces: [
            MobileWorkspacePreview(
                id: .init(rawValue: RoutingHostRouter.workspaceID),
                name: "Routing Workspace",
                terminals: terminals
            ),
        ],
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
        workspaceID: RoutingHostRouter.workspaceID,
        terminalID: RoutingHostRouter.terminalA,
        macDeviceID: "test-mac",
        macDisplayName: "Test Mac",
        routes: [route],
        expiresAt: Date().addingTimeInterval(3600)
    )
    store.remoteClient = MobileCoreRPCClient(
        runtime: runtime,
        route: route,
        ticket: ticket,
        allowsStackAuthFallback: true
    )
    store.foregroundMacDeviceID = "test-mac"
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
