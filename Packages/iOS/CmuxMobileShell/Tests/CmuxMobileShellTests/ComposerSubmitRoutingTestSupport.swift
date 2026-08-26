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
    struct PasteImageRecord: Sendable {
        var surfaceID: String
        var format: String
    }
    struct PasteRecord: Sendable {
        var surfaceID: String
        var text: String
    }
    struct AttachmentUploadRecord: Sendable {
        var fileName: String
        var offset: Int
        var last: Bool
        var totalBytes: Int
    }
    struct WorkspaceCreateRecord: Sendable, Equatable {
        var groupID: String?
        var title: String?
        var workingDirectory: String?
        var initialCommand: String?
        var initialEnv: [String: String]?
        var operationID: String? = nil
    }
    private(set) var pasteImages: [PasteImageRecord] = []
    private(set) var pastes: [PasteRecord] = []
    private(set) var attachmentUploads: [AttachmentUploadRecord] = []
    private var rejectAttachmentUpload = false
    let terminalInputRecorder = RoutingTerminalInputRecorder()
    private(set) var directorySearchQueries: [String] = []
    private(set) var dismisses: [(notificationIDs: [String], clientID: String?)] = []
    private var notificationFeedMarkAllReadCount = 0
    private var workspaceCreates: [WorkspaceCreateRecord] = []
    /// Reject the Nth (0-based) and later paste_image requests; `nil` accepts all.
    private var rejectPasteImageFromIndex: Int?
    private var holdFirstPasteImage = false
    private var firstPasteImageHeld = false
    private var firstPasteImageContinuation: CheckedContinuation<Void, Never>?
    private var firstPasteImageReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var workspaceCreateCount = 0
    private var hostCapabilities = ["workspace.task_create.v1"]
    private var rejectWorkspaceCreate = false
    private var workspaceCreateError: (code: String?, message: String)?
    private var workspaceCreateResponseCreatedWorkspaceID: String? = "workspace-created"
    private var workspaceCreateResponseIncludesCreatedWorkspace = true
    private(set) var directoryListRequests: [(path: String, offset: Int, limit: Int)] = []
    private var directoryListError: (code: String?, message: String)?
    private var directorySearchError: (code: String?, message: String)?
    private var taskModelsByProvider: [String: [MobileTaskAgentModel]] = [:]
    private var taskModelListProviders: [String] = []
    private var holdTaskModelList = false
    private var taskModelListHeld = false
    private var taskModelListContinuation: CheckedContinuation<Void, Never>?
    private var taskModelListReachedWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdFirstWorkspaceCreate = false
    private var firstWorkspaceCreateHeld = false
    private var firstWorkspaceCreateContinuation: CheckedContinuation<Void, Never>?
    private var firstWorkspaceCreateReachedWaiters: [CheckedContinuation<Void, Never>] = []

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

    func setWorkspaceCreateError(code: String?, message: String) {
        workspaceCreateError = (code, message)
    }

    func setWorkspaceCreateResponse(
        createdWorkspaceID: String?,
        includesCreatedWorkspace: Bool = true
    ) {
        workspaceCreateResponseCreatedWorkspaceID = createdWorkspaceID
        workspaceCreateResponseIncludesCreatedWorkspace = includesCreatedWorkspace
    }

    func setDirectorySearchError(code: String?, message: String) {
        directorySearchError = (code, message)
    }

    func setDirectoryListError(code: String?, message: String) {
        directoryListError = (code, message)
    }

    func setHostCapabilities(_ capabilities: [String]) {
        hostCapabilities = capabilities
    }

    func setTaskModels(
        _ models: [MobileTaskAgentModel],
        provider: MobileTaskAgentProvider
    ) {
        taskModelsByProvider[provider.rawValue] = models
    }

    func setHoldTaskModelList(_ hold: Bool) {
        holdTaskModelList = hold
    }

    func awaitTaskModelListReached() async {
        if taskModelListHeld { return }
        await withCheckedContinuation { taskModelListReachedWaiters.append($0) }
    }

    func releaseTaskModelList() {
        let continuation = taskModelListContinuation
        taskModelListContinuation = nil
        continuation?.resume()
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
    func recordedWorkspaceCreateGroupIDs() -> [String?] { workspaceCreates.map(\.groupID) }
    func recordedWorkspaceCreates() -> [WorkspaceCreateRecord] { workspaceCreates }

    func recordedPasteImages() -> [PasteImageRecord] { pasteImages }
    func recordedPastes() -> [PasteRecord] { pastes }
    func recordedAttachmentUploads() -> [AttachmentUploadRecord] { attachmentUploads }

    /// Reject every mobile.task.attachment.upload with an error frame, modeling
    /// a host that cannot store the file (the composer must keep the chip and
    /// leave the text unsent).
    func setRejectAttachmentUpload(_ reject: Bool) {
        rejectAttachmentUpload = reject
    }
    func recordedDirectorySearchQueries() -> [String] { directorySearchQueries }
    func recordedTaskModelListProviders() -> [String] { taskModelListProviders }
    func recordedDirectoryListRequests() -> [(path: String, offset: Int, limit: Int)] {
        directoryListRequests
    }
    func recordedDismisses() -> [(notificationIDs: [String], clientID: String?)] { dismisses }
    func recordedNotificationFeedMarkAllReadCount() -> Int { notificationFeedMarkAllReadCount }

    /// Sendable extract of the request fields the router needs, pulled off the
    /// non-Sendable params dictionary before crossing the Task boundary.
    struct RequestInfo: Sendable {
        var method: String?
        var id: String?
        var streamID: String?
        var surfaceID: String?
        var imageFormat: String?
        var text: String?
        var notificationIDs: [String]?
        var clientID: String?
        var groupID: String?
        var title: String?
        var workingDirectory: String?
        var initialCommand: String?
        var initialEnv: [String: String]?
        var operationID: String?
        var query: String?
        var directoryPath: String?
        var directoryOffset: Int?
        var directoryLimit: Int?
        var provider: String?
        var fileName: String?
        var uploadOffset: Int?
        var uploadLast: Bool?
        var uploadTotalBytes: Int?
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
                "capabilities": hostCapabilities,
            ])
        case "mobile.events.subscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": "test-stream",
                "topics": ["workspace.updated", "terminal.render_grid"],
                "already_subscribed": false,
            ])
        case "workspace.create":
            workspaceCreateCount += 1
            workspaceCreates.append(WorkspaceCreateRecord(
                groupID: info.groupID,
                title: info.title,
                workingDirectory: info.workingDirectory,
                initialCommand: info.initialCommand,
                initialEnv: info.initialEnv,
                operationID: info.operationID
            ))
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
            if let workspaceCreateError {
                return try? Self.errorFrame(
                    id: id,
                    code: workspaceCreateError.code,
                    message: workspaceCreateError.message
                )
            }
            var workspaces: [[String: Any]] = [[
                "id": Self.workspaceID,
                "title": "Routing Workspace",
                "current_directory": "/tmp/route",
                "is_selected": false,
                "terminals": [],
            ]]
            if workspaceCreateResponseIncludesCreatedWorkspace {
                workspaces.append([
                    "id": "workspace-created",
                    "title": "Created Workspace",
                    "current_directory": "/tmp/created",
                    "is_selected": true,
                    "terminals": [
                        [
                            "id": "terminal-created",
                            "title": "Created",
                            "current_directory": "/tmp/created",
                            "is_focused": true,
                            "is_ready": true,
                        ],
                    ],
                ])
            }
            var result: [String: Any] = [
                "workspaces": workspaces,
                "created_terminal_id": "terminal-created",
            ]
            if let workspaceCreateResponseCreatedWorkspaceID {
                result["created_workspace_id"] = workspaceCreateResponseCreatedWorkspaceID
            }
            return try? Self.resultFrame(id: id, result: result)
        case "mobile.directory.search":
            directorySearchQueries.append(info.query ?? "")
            if let directorySearchError {
                return try? Self.errorFrame(
                    id: id,
                    code: directorySearchError.code,
                    message: directorySearchError.message
                )
            }
            return try? Self.resultFrame(id: id, result: [
                "directories": [
                    "/Users/test/Dev/Manaflow/cmux",
                    "/Users/test/Dev/Manaflow/cmuxterm-hq",
                ],
            ])
        case "mobile.directory.list":
            let path = info.directoryPath ?? ""
            let offset = info.directoryOffset ?? 0
            let limit = info.directoryLimit ?? 50
            directoryListRequests.append((path, offset, limit))
            if let directoryListError {
                return try? Self.errorFrame(
                    id: id,
                    code: directoryListError.code,
                    message: directoryListError.message
                )
            }
            let allEntries: [[String: Any]] = [
                [
                    "name": ".hidden",
                    "path": "/Users/test/.hidden",
                    "is_hidden": true,
                    "is_package": false,
                    "is_symbolic_link": false,
                    "is_readable": true,
                ],
                [
                    "name": "Projects",
                    "path": "/Users/test/Projects",
                    "is_hidden": false,
                    "is_package": false,
                    "is_symbolic_link": false,
                    "is_readable": true,
                ],
            ]
            let boundedOffset = min(max(offset, 0), allEntries.count)
            let end = min(boundedOffset + max(limit, 0), allEntries.count)
            return try? Self.resultFrame(id: id, result: [
                "current_path": "/Users/test",
                "parent_path": "/Users",
                "entries": Array(allEntries[boundedOffset..<end]),
                "offset": boundedOffset,
                "limit": limit,
                "total_count": allEntries.count,
                "next_offset": end < allEntries.count ? end : NSNull() as Any,
            ])
        case "mobile.task.models.list":
            let provider = info.provider ?? ""
            taskModelListProviders.append(provider)
            if holdTaskModelList {
                taskModelListHeld = true
                let reachedWaiters = taskModelListReachedWaiters
                taskModelListReachedWaiters = []
                for waiter in reachedWaiters { waiter.resume() }
                await withCheckedContinuation { taskModelListContinuation = $0 }
            }
            let models: [[String: Any]] = taskModelsByProvider[provider, default: []].map { model in
                var object: [String: Any] = [
                    "id": model.id,
                    "display_name": model.displayName,
                    "efforts": model.efforts.map { effort in
                        var effortObject: [String: Any] = [
                            "id": effort.id,
                            "display_name": effort.displayName,
                        ]
                        if let description = effort.description {
                            effortObject["description"] = description
                        }
                        return effortObject
                    },
                ]
                if let defaultEffortID = model.defaultEffortID {
                    object["default_effort_id"] = defaultEffortID
                }
                return object
            }
            return try? Self.resultFrame(id: id, result: [
                "source": "discovered",
                "models": models,
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
        case "mobile.task.attachment.upload":
            let fileName = info.fileName ?? ""
            let last = info.uploadLast ?? false
            let totalBytes = info.uploadTotalBytes ?? 0
            attachmentUploads.append(AttachmentUploadRecord(
                fileName: fileName,
                offset: info.uploadOffset ?? 0,
                last: last,
                totalBytes: totalBytes
            ))
            if rejectAttachmentUpload {
                return try? Self.errorFrame(id: id, message: "attachment upload rejected")
            }
            var result: [String: Any] = ["received_bytes": totalBytes]
            if last {
                result["path"] = "/tmp/uploads/\(fileName)"
            }
            return try? Self.resultFrame(id: id, result: result)
        case "terminal.input":
            return await terminalInputResponse(info)
        case "notification.dismiss":
            dismisses.append((
                notificationIDs: info.notificationIDs ?? [],
                clientID: info.clientID
            ))
            return try? Self.resultFrame(id: id, result: [:])
        case "notification.feed.mark_all_read":
            notificationFeedMarkAllReadCount += 1
            return try? Self.resultFrame(id: id, result: [
                "marked": 1,
                "revision": notificationFeedMarkAllReadCount + 100,
            ])
        case "mobile.events.unsubscribe":
            return try? Self.resultFrame(id: id, result: [
                "stream_id": info.streamID ?? "",
                "removed": true,
            ])
        case "mobile.terminal.replay", "mobile.terminal.viewport":
            return try? Self.resultFrame(id: id, result: [:])
        default:
            return try? Self.errorFrame(id: id, message: "Unexpected method \(method ?? "nil")")
        }
    }

    static func resultFrame(id: String?, result: [String: Any]) throws -> Data {
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": true,
            "result": result,
        ]
        return try MobileSyncFrameCodec.encodeFrame(JSONSerialization.data(withJSONObject: envelope))
    }

    static func errorFrame(id: String?, code: String? = nil, message: String) throws -> Data {
        var error: [String: Any] = ["message": message]
        if let code {
            error["code"] = code
        }
        let envelope: [String: Any] = [
            "id": id ?? UUID().uuidString,
            "ok": false,
            "error": error,
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
                streamID: params?["stream_id"] as? String,
                surfaceID: params?["surface_id"] as? String,
                imageFormat: params?["image_format"] as? String,
                text: params?["text"] as? String,
                notificationIDs: params?["notification_ids"] as? [String],
                clientID: params?["client_id"] as? String,
                groupID: params?["group_id"] as? String,
                title: params?["title"] as? String,
                workingDirectory: params?["working_directory"] as? String,
                initialCommand: params?["initial_command"] as? String,
                initialEnv: params?["initial_env"] as? [String: String],
                operationID: params?["operation_id"] as? String,
                query: params?["query"] as? String,
                directoryPath: params?["path"] as? String,
                directoryOffset: params?["offset"] as? Int,
                directoryLimit: params?["limit"] as? Int,
                provider: params?["provider"] as? String,
                fileName: params?["file_name"] as? String,
                uploadOffset: params?["offset"] as? Int,
                uploadLast: params?["last"] as? Bool,
                uploadTotalBytes: params?["total_bytes"] as? Int
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
