import CmuxNextPages
import Foundation

extension AgentPaneView {
    static func nativeUploadTicket(_ params: [String: Any]) -> AgentPaneUploadSendTicket? {
        guard Set(params.keys) == ["token", "name", "type", "size", "sessionId", "promptId", "ticket"] else { return nil }
        return AgentPaneUploadSendTicket(beginParams: params)
    }

    /// Browser Blob bytes are pulled by the Chromium host in the caller's execution context.
    /// This callback sends only metadata and native socket upload chunks; no bytes enter the page binding.
    @MainActor static func chromiumUploadHandler(for model: AgentPaneModel?) -> ChromiumPageHostBridge.UploadHandler? {
        guard let model else { return nil }
        var endedUploads = Set<String>()
        model.transport.gestures.onUploadHoldsEnded = { endedUploads.formUnion($0) }
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
                return AgentPaneReply.failure(code: "gesture_required", message: "Send again to authorize this upload")
            }
            var held = true
            var uploadId: String?
            var offset = 0
            do {
                let started = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_begin",
                    params: ["sessionId": sessionId, "fileName": name, "size": size])
                guard let id = started["uploadId"] as? String, !id.isEmpty else { throw AgentPaneUploadError.rpc("missing upload id") }
                uploadId = id
                offset = (started["offset"] as? NSNumber)?.intValue ?? 0
                guard offset == 0 else { throw AgentPaneUploadError.rpc("invalid initial upload offset") }
                for try await chunk in chunks {
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
                        guard endedUploads.remove(upload) == nil,
                              model.transport.gestures.uploadProgressed(upload) else {
                            throw AgentPaneUploadError.rpc("gesture_required")
                        }
                        at = end
                    }
                }
                guard offset == size else { throw AgentPaneUploadError.rpc("upload size mismatch") }
                let finished = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_finish",
                    params: ["sessionId": sessionId, "uploadId": id, "fileName": name, "size": size])
                _ = model.transport.gestures.releaseUpload(upload)
                held = false
                var result: [String: Any] = ["token": token, "uploadId": id, "offset": offset, "size": size]
                if let path = finished["path"] as? String { result["path"] = path }
                return AgentPaneReply.success(result)
            } catch {
                if let id = uploadId {
                    _ = try? await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_cancel",
                        params: ["sessionId": sessionId, "uploadId": id])
                }
                if held { _ = model.transport.gestures.releaseUpload(upload) }
                return AgentPaneReply.failure(code: "upload_failed", message: "The upload could not be completed")
            }
        }
    }
}
