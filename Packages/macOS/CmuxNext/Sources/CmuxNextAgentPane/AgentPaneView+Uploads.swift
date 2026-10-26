import CmuxNextPages
import Foundation

extension AgentPaneView {
    /// Browser Blob bytes are pulled by the Chromium host in the caller's execution context.
    /// This callback sends only metadata and native socket upload chunks; no bytes enter the page binding.
    @MainActor static func chromiumUploadHandler(for model: AgentPaneModel?) -> ChromiumPageHostBridge.UploadHandler? {
        guard let model else { return nil }
        return { page, context, params, chunks in
            guard let sessionId = params["sessionId"] as? String, !sessionId.isEmpty,
                  let name = params["name"] as? String, !name.isEmpty,
                  let sizeNumber = params["size"] as? NSNumber,
                  sizeNumber.int64Value >= 0, UInt64(sizeNumber.int64Value) <= UInt64(Int.max),
                  let token = params["token"] as? String, !token.isEmpty,
                  sessionId == model.sessionId,
                  let connection = model.transport.connection
            else { return AgentPaneReply.failure(code: "upload_invalid", message: "Invalid upload request") }
            let size = Int(sizeNumber.int64Value)
            var uploadId: String?
            var offset = 0
            do {
                let started = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_begin",
                    params: ["sessionId": sessionId, "fileName": name, "size": size])
                guard let id = started["uploadId"] as? String, !id.isEmpty else { throw AgentPaneUploadError.rpc("missing upload id") }
                uploadId = id
                offset = (started["offset"] as? NSNumber)?.intValue ?? 0
                for try await chunk in chunks {
                    var at = 0
                    while at < chunk.count {
                        let end = min(at + 512 * 1024, chunk.count)
                        let part = Data(chunk[at..<end])
                        let sentOffset = offset
                        let reply = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_chunk",
                            params: ["sessionId": sessionId, "uploadId": id, "offset": offset, "data": part.base64EncodedString()])
                        offset = (reply["offset"] as? NSNumber)?.intValue ?? (sentOffset + part.count)
                        guard offset == sentOffset + part.count else { throw AgentPaneUploadError.rpc("invalid upload offset") }
                        at = end
                    }
                }
                guard offset == size else { throw AgentPaneUploadError.rpc("upload size mismatch") }
                _ = try await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_finish",
                    params: ["sessionId": sessionId, "uploadId": id, "fileName": name, "size": size])
                return AgentPaneReply.success(["token": token, "uploadId": id, "offset": offset, "size": size])
            } catch {
                if let id = uploadId {
                    _ = try? await model.transport.uploadControl(connection: connection, method: "_acpmux/file_put_cancel",
                        params: ["sessionId": sessionId, "uploadId": id])
                }
                return AgentPaneReply.failure(code: "upload_failed", message: "The upload could not be completed")
            }
        }
    }
}
