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
    struct TerminalInteractionRecord: Sendable {
        var method: String
        var surfaceID: String
        var clientID: String?
        var interactionSessionID: String?
        var interactionEpoch: Int?
        var clientScrollRevision: Int?
        var col: Int?
        var row: Int?
    }
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
    private var rejectWorkspaceCreate = false
    private var holdFirstWorkspaceCreate = false
    private var firstWorkspaceCreateHeld = false
    private var firstWorkspaceCreateContinuation: CheckedContinuation<Void, Never>?
    private var firstWorkspaceCreateReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalInteractions: [TerminalInteractionRecord] = []
    private var holdFirstTerminalScroll = false
    private var firstTerminalScrollHeld = false
    private var firstTerminalScrollContinuation: CheckedContinuation<Void, Never>?
    private var firstTerminalScrollReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldTerminalInputMethod: String?
    private var heldTerminalInputContinuation: CheckedContinuation<Void, Never>?
    private var heldTerminalInputReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var transportCloseCount = 0

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

    func recordedWorkspaceCreateCount() -> Int { workspaceCreateCount }
    func recordedWorkspaceCreateGroupIDs() -> [String?] { workspaceCreateGroupIDs }

    func recordedPasteImages() -> [PasteImageRecord] { pasteImages }
    func recordedPastes() -> [PasteRecord] { pastes }
    func recordedDismisses() -> [(notificationIDs: [String], clientID: String?)] { dismisses }
    func recordedTerminalInteractions() -> [TerminalInteractionRecord] { terminalInteractions }

    func setHoldFirstTerminalScroll(_ hold: Bool) {
        holdFirstTerminalScroll = hold
    }

    func awaitFirstTerminalScrollReached() async {
        if firstTerminalScrollHeld { return }
        await withCheckedContinuation { firstTerminalScrollReachedWaiters.append($0) }
    }

    func releaseFirstTerminalScroll() {
        let continuation = firstTerminalScrollContinuation
        firstTerminalScrollContinuation = nil
        continuation?.resume()
    }

    func holdNextTerminalInput(method: String) {
        heldTerminalInputMethod = method
    }

    func awaitHeldTerminalInputReached() async {
        if heldTerminalInputContinuation != nil { return }
        await withCheckedContinuation { heldTerminalInputReachedWaiters.append($0) }
    }

    func releaseHeldTerminalInput() {
        heldTerminalInputMethod = nil
        let continuation = heldTerminalInputContinuation
        heldTerminalInputContinuation = nil
        continuation?.resume()
    }

    func recordedTransportCloseCount() -> Int { transportCloseCount }

    func transportDidClose() {
        transportCloseCount += 1
    }

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
        var interactionSessionID: String?
        var groupID: String?
        var interactionEpoch: Int?
        var clientScrollRevision: Int?
        var col: Int?
        var row: Int?
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
                        "terminals": [],
                    ],
                    [
                        "id": "workspace-created",
                        "title": "Created Workspace",
                        "is_selected": true,
                        "terminals": [
                            [
                                "id": "terminal-created",
                                "title": "Created",
                                "is_focused": true,
                                "is_ready": true,
                            ],
                        ],
                    ],
                ],
                "created_workspace_id": "workspace-created",
                "created_terminal_id": "terminal-created",
            ])
        case "terminal.paste_image":
            let surfaceID = info.surfaceID ?? ""
            let format = info.imageFormat ?? ""
            let index = pasteImages.count
            pasteImages.append(PasteImageRecord(surfaceID: surfaceID, format: format))
            await holdTerminalInputIfNeeded(method: method)
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
            await holdTerminalInputIfNeeded(method: method)
            return try? Self.resultFrame(id: id, result: [:])
        case "terminal.input":
            terminalInteractions.append(TerminalInteractionRecord(
                method: method ?? "",
                surfaceID: info.surfaceID ?? "",
                clientID: info.clientID,
                interactionSessionID: info.interactionSessionID,
                interactionEpoch: info.interactionEpoch,
                clientScrollRevision: nil,
                col: nil,
                row: nil
            ))
            await holdTerminalInputIfNeeded(method: method)
            return try? Self.resultFrame(id: id, result: [:])
        case "mobile.terminal.scroll":
            terminalInteractions.append(TerminalInteractionRecord(
                method: method ?? "",
                surfaceID: info.surfaceID ?? "",
                clientID: info.clientID,
                interactionSessionID: info.interactionSessionID,
                interactionEpoch: info.interactionEpoch,
                clientScrollRevision: info.clientScrollRevision,
                col: info.col,
                row: info.row
            ))
            if terminalInteractions.filter({ $0.method == "mobile.terminal.scroll" }).count == 1,
               holdFirstTerminalScroll {
                firstTerminalScrollHeld = true
                let reachedWaiters = firstTerminalScrollReachedWaiters
                firstTerminalScrollReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { firstTerminalScrollContinuation = $0 }
            }
            return try? Self.resultFrame(id: id, result: [
                "accepted": true,
                "interaction_epoch": info.interactionEpoch ?? 0,
                "client_scroll_revision": info.clientScrollRevision ?? 0,
                "render_revision": 1,
            ])
        case "mobile.terminal.mouse":
            terminalInteractions.append(TerminalInteractionRecord(
                method: method ?? "",
                surfaceID: info.surfaceID ?? "",
                clientID: info.clientID,
                interactionSessionID: info.interactionSessionID,
                interactionEpoch: info.interactionEpoch,
                clientScrollRevision: info.clientScrollRevision,
                col: info.col,
                row: info.row
            ))
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

    private func holdTerminalInputIfNeeded(method: String?) async {
        guard method == heldTerminalInputMethod else { return }
        let waiters = heldTerminalInputReachedWaiters
        heldTerminalInputReachedWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { heldTerminalInputContinuation = $0 }
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
}

struct RoutingTransportFactory: CmxByteTransportFactory {
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
                clientID: params?["client_id"] as? String,
                interactionSessionID: params?["interaction_session_id"] as? String,
                groupID: params?["group_id"] as? String,
                interactionEpoch: params?["interaction_epoch"] as? Int,
                clientScrollRevision: params?["client_scroll_revision"] as? Int,
                col: params?["col"] as? Int,
                row: params?["row"] as? Int
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
        await router.transportDidClose()
    }

    private func deliver(_ frame: Data) {
        guard !isClosed else { return }
        if receiveWaiters.isEmpty {
            pendingFrames.append(frame)
            return
        }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: frame)
    }
}
