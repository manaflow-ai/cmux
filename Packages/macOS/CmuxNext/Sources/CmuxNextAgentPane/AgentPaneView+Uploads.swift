import CmuxNextPages
import CmuxNextSettings
import Foundation

@MainActor final class NativeUploadResult {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

@MainActor final class AgentPaneUploadCoordinator {
    struct Record {
        var size: Int
        var uploadId: String?
        var state = "uploading"
        var error: [String: Any]?
        var sessionId: String
        var connection: Int
        var context: Int
    }
    weak var model: AgentPaneModel?
    var active: [String: Task<NativeUploadResult, Never>] = [:]
    var uploadTokens: [String: String] = [:]
    var records: [String: Record] = [:]
    var publish: (@MainActor (AgentPageEvent) -> Bool)?

    init(model: AgentPaneModel) { self.model = model }

    func start(_ token: String, size: Int, upload: String, sessionId: String, connection: Int, context: Int) -> Bool {
        guard records[token] == nil else { return false }
        records[token] = Record(size: size, sessionId: sessionId, connection: connection, context: context)
        uploadTokens[upload] = token
        return true
    }

    func assigned(_ token: String, uploadId: String) {
        records[token]?.uploadId = uploadId
    }

    func terminal(_ token: String, state: String, error: [String: Any]? = nil) {
        guard var record = records[token], record.state == "uploading" else { return }
        guard state == "finished" ? record.uploadId?.isEmpty == false : true else { return }
        record.state = state
        record.error = error
        records[token] = record
        var value: [String: Any] = ["token": token, "state": state, "size": record.size]
        if let id = record.uploadId { value["uploadId"] = id }
        if let error { value["error"] = error }
        if let json = JSONValue(foundation: value) { _ = publish?(AgentPageEvent(kind: "uploads.state", value: json)) }
    }

    func query(_ op: String, context: Int, params: [String: Any]) async -> [String: Any]? {
        guard let token = params["token"] as? String, !token.isEmpty else {
            return AgentPaneReply.failure(code: "upload_invalid", message: "Missing upload token")
        }
        guard let record = records[token], record.context == context,
              let model, record.sessionId == model.sessionId, record.connection == model.transport.connection else {
            return AgentPaneReply.failure(code: "upload_unknown", message: "Unknown upload token")
        }
        let hadActiveTask = active[token] != nil && record.state == "uploading"
        if op == "cmux.agent.uploads.cancel", let task = active[token], record.state == "uploading" {
            task.cancel()
            _ = await task.value
        }
        if op == "cmux.agent.uploads.cancel", let updated = records[token], updated.state != "uploading",
           (!hadActiveTask || updated.state == "finished"),
           let id = updated.uploadId {
            guard await model.transport.cancelUpload(connection: updated.connection, sessionId: updated.sessionId, uploadId: id) else {
                return AgentPaneReply.failure(code: "upload_cancel_failed", message: "The upload cleanup was not acknowledged")
            }
        }
        var value: [String: Any] = ["token": token, "state": records[token]?.state ?? record.state, "size": record.size]
        if let id = records[token]?.uploadId { value["uploadId"] = id }
        if let error = records[token]?.error { value["error"] = error }
        return AgentPaneReply.success(value)
    }
}

extension AgentPaneView {
    static func nativeUploadTicket(_ params: [String: Any]) -> AgentPaneUploadSendTicket? {
        guard Set(params.keys) == ["token", "name", "type", "size", "sessionId", "promptId", "ticket"] else { return nil }
        return AgentPaneUploadSendTicket(beginParams: params)
    }

    /// Browser Blob bytes are pulled by the Chromium host in the caller's execution context.
    /// This callback sends only metadata and native socket upload chunks; no bytes enter the page binding.
    @MainActor static func chromiumUploadHandler(for model: AgentPaneModel?) -> ChromiumPageHostBridge.UploadHandler? {
        guard let model else { return nil }
        let coordinator = model.nativeUploadCoordinator ?? {
            let value = AgentPaneUploadCoordinator(model: model)
            model.nativeUploadCoordinator = value
            return value
        }()
        model.transport.gestures.onUploadHoldsEnded = { ended in
            for upload in ended {
                if let token = coordinator.uploadTokens[upload] { coordinator.active[token]?.cancel() }
            }
        }
        return { page, context, params, chunks in
            guard AgentPaneView.nativeUploadTicket(params) != nil,
                  params["type"] is String,
                  let sessionId = params["sessionId"] as? String, !sessionId.isEmpty,
                  let name = params["name"] as? String, !name.isEmpty,
                  let sizeNumber = params["size"] as? NSNumber,
                  sizeNumber.int64Value >= 0, sizeNumber.stringValue == String(sizeNumber.int64Value),
                  UInt64(sizeNumber.int64Value) <= UInt64(Int.max),
                  let token = params["token"] as? String, !token.isEmpty,
                  let promptId = params["promptId"] as? String, !promptId.isEmpty,
                  let ticket = params["ticket"] as? String, !ticket.isEmpty,
                  sessionId == model.sessionId,
                  let connection = model.transport.connection
            else { return AgentPaneReply.failure(code: "upload_invalid", message: "Invalid upload request") }
            let size = Int(sizeNumber.int64Value)
            let upload = UUID().uuidString
            guard model.transport.holdSendTicket(ticket, upload: upload, sessionId: sessionId, promptId: promptId) else {
                return AgentPaneReply.failure(code: "transport.gesture_required", message: "Send again to authorize this upload")
            }
            guard coordinator.start(token, size: size, upload: upload, sessionId: sessionId, connection: connection, context: context) else {
                _ = model.transport.gestures.releaseUpload(upload)
                return AgentPaneReply.failure(code: "upload_in_progress", message: "An upload with this token is already active")
            }
            let task = Task { @MainActor () -> NativeUploadResult in
                defer { _ = model.transport.gestures.releaseUpload(upload) }
                var uploadId: String?
                var offset = 0
                do {
                    try Task.checkCancellation()
                    let started = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_begin",
                        params: ["sessionId": sessionId, "fileName": name, "size": size])
                    guard let id = started["uploadId"] as? String, !id.isEmpty else { throw AgentPaneUploadError.rpc("missing upload id") }
                    uploadId = id
                    coordinator.assigned(token, uploadId: id)
                    try Task.checkCancellation()
                    offset = (started["offset"] as? NSNumber)?.intValue ?? 0
                    guard offset == 0 else { throw AgentPaneUploadError.rpc("invalid initial upload offset") }
                    for try await chunk in chunks {
                        try Task.checkCancellation()
                        var at = 0
                        while at < chunk.count {
                            let end = min(at + 512 * 1024, chunk.count)
                            let part = Data(chunk[at..<end])
                            let sentOffset = offset
                            let reply = try await model.transport.uploadChunk(connection: connection,
                                sessionId: sessionId, uploadId: id, offset: offset, bytes: part)
                            guard let acknowledged = reply["offset"] as? NSNumber,
                                  acknowledged.intValue == sentOffset + part.count
                            else { throw AgentPaneUploadError.rpc("invalid upload offset") }
                            offset = acknowledged.intValue
                            guard model.transport.gestures.uploadProgressed(upload) else { throw CancellationError() }
                            at = end
                        }
                    }
                    try Task.checkCancellation()
                    guard offset == size else { throw AgentPaneUploadError.rpc("upload size mismatch") }
                    let finished = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_finish",
                        params: ["sessionId": sessionId, "uploadId": id, "fileName": name, "size": size])
                    // A successful daemon finish is terminal. Record it before any cancellation
                    // or ticket-release work can race with an explicit uploads.cancel call.
                    coordinator.terminal(token, state: "finished")
                    _ = model.transport.gestures.releaseUpload(upload)
                    var result: [String: Any] = ["token": token, "uploadId": id, "offset": offset, "size": size]
                    if let path = finished["path"] as? String { result["path"] = path }
                    return NativeUploadResult(AgentPaneReply.success(result))
                } catch {
                    var cleanupFailed = false
                    if let id = uploadId {
                        cleanupFailed = !(await model.transport.cancelUpload(connection: connection, sessionId: sessionId, uploadId: id))
                    }
                    let cancelled = error is CancellationError && !cleanupFailed
                    let failure = (error as? AgentPaneUploadError)?.failure
                    var details: [String: Any] = [:]
                    if let failure { for (key, value) in failure.details { details[key] = value } }
                    var eventError: [String: Any]?
                    if let failure {
                        eventError = ["code": failure.code, "message": failure.message]
                        for (key, value) in failure.details { eventError?[key] = value }
                        if cleanupFailed { eventError?["cleanupError"] = "upload_cancel_failed" }
                    } else if cleanupFailed {
                        eventError = ["code": "upload_cancel_failed", "message": "The upload cleanup was not acknowledged"]
                    } else if !cancelled {
                        eventError = ["code": "upload_failed", "message": "The upload could not be completed"]
                    }
                    coordinator.terminal(token, state: cancelled ? "cancelled" : "failed", error: eventError)
                    if cleanupFailed {
                        if let failure {
                            details["cleanupError"] = "upload_cancel_failed"
                            return NativeUploadResult(AgentPaneReply.failure(code: failure.code, message: failure.message,
                                                                             details: details, retryable: nil, origin: "daemon"))
                        }
                        return NativeUploadResult(AgentPaneReply.failure(code: "upload_cancel_failed", message: "The upload cleanup was not acknowledged"))
                    }
                    if let failure {
                        return NativeUploadResult(AgentPaneReply.failure(code: failure.code, message: failure.message,
                                                                         details: details.isEmpty ? nil : details, retryable: nil, origin: "daemon"))
                    }
                    return NativeUploadResult(AgentPaneReply.failure(
                        code: cancelled ? "transport.gesture_required" : "upload_failed",
                        message: "The upload could not be completed"))
                }
            }
            coordinator.active[token] = task
            let result = await task.value
            coordinator.active[token] = nil
            return result.value
        }
    }

    @MainActor static func chromiumUploadQueryHandler(for model: AgentPaneModel?) -> ChromiumPageHostBridge.UploadQueryHandler? {
        guard let model else { return nil }
        let coordinator = model.nativeUploadCoordinator ?? {
            let value = AgentPaneUploadCoordinator(model: model)
            model.nativeUploadCoordinator = value
            return value
        }()
        return { op, context, params in await coordinator.query(op, context: context, params: params) }
    }
}
