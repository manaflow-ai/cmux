import Foundation

/// Pulls one bounded chunk only when the upload loop asks, after its prior daemon ACK.
@MainActor
final class ChromiumUploadBlobReader {
    private let page: any PageChromiumPage
    private let context: Int
    private let token: String
    private var objectID: String?
    private var handle: String?
    private var ended = false

    init(page: any PageChromiumPage, context: Int, token: String) {
        self.page = page
        self.context = context
        self.token = token
    }

    func next() async throws -> Data? {
        try Task.checkCancellation()
        guard !ended else { return nil }
        do {
            if handle == nil {
                guard !token.isEmpty else { throw AgentPageUploadError.invalidBlob }
                let tokenJSON = ChromiumPageHostWire.jsonString(token)
                let lookup = try await page.devTools("Runtime.evaluate", params: [
                    "expression": "globalThis.__cmuxUploadBlobs?.get(\(tokenJSON))",
                    "contextId": context, "returnByValue": false, "silent": true,
                ])
                guard let object = ChromiumPageHostWire.object(lookup),
                      object["exceptionDetails"] == nil,
                      let result = object["result"] as? [String: Any],
                      let id = result["objectId"] as? String, !id.isEmpty
                else { throw AgentPageUploadError.invalidBlob }
                objectID = id
                let resolved = try await page.devTools("IO.resolveBlob", params: ["objectId": id])
                guard let uuid = ChromiumPageHostWire.object(resolved)?["uuid"] as? String, !uuid.isEmpty
                else { throw AgentPageUploadError.invalidBlob }
                handle = "blob:" + uuid
            }
            guard let handle else { throw AgentPageUploadError.invalidBlob }
            let read = try await page.devTools("IO.read", params: ["handle": handle, "size": 1 << 20])
            guard let object = ChromiumPageHostWire.object(read), let text = object["data"] as? String
            else { throw AgentPageUploadError.invalidBlob }
            let chunk: Data
            if object["base64Encoded"] as? Bool == true {
                guard let decoded = Data(base64Encoded: text) else { throw AgentPageUploadError.invalidBlob }
                chunk = decoded
            } else {
                chunk = Data(text.utf8)
            }
            ended = object["eof"] as? Bool == true
            return chunk.isEmpty && ended ? nil : chunk
        } catch {
            await close()
            throw error
        }
    }

    func close() async {
        ended = true
        if let handle {
            self.handle = nil
            _ = try? await page.devTools("IO.close", params: ["handle": handle])
        }
        if let objectID {
            self.objectID = nil
            _ = try? await page.devTools("Runtime.releaseObject", params: ["objectId": objectID])
        }
    }
}
