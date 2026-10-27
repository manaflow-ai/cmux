import Foundation
import CmuxNextCompat

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
                let lookup = try await call("Runtime.evaluate", params: [
                    "expression": "globalThis.__cmuxUploadBlobs?.get(\(tokenJSON))",
                    "contextId": context, "returnByValue": false, "silent": true,
                ])
                guard let object = ChromiumPageHostWire.object(lookup),
                      object["exceptionDetails"] == nil,
                      let result = object["result"] as? [String: Any],
                      let id = result["objectId"] as? String, !id.isEmpty
                else { throw AgentPageUploadError.invalidBlob }
                objectID = id
                let resolved = try await call("IO.resolveBlob", params: ["objectId": id])
                guard let uuid = ChromiumPageHostWire.object(resolved)?["uuid"] as? String, !uuid.isEmpty
                else { throw AgentPageUploadError.invalidBlob }
                handle = "blob:" + uuid
            }
            guard let handle else { throw AgentPageUploadError.invalidBlob }
            let read = try await call("IO.read", params: ["handle": handle, "size": 1 << 20])
            try Task.checkCancellation()
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

    /// The CEF reply waiter has its own deadline; cancellation ends our wait independently.
    private func call(_ method: String, params: [String: any Sendable]) async throws -> String {
        try Task.checkCancellation()
        let pending = Mutex((waiter: Optional<CheckedContinuation<String, any Error>>.none, cancelled: false))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = pending.withLock { state in
                    if state.cancelled { return true }
                    state.waiter = continuation
                    return false
                }
                guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                Task { [page] in
                    guard !pending.withLock({ $0.cancelled }) else { return }
                    let result: Result<String, any Error>
                    do { result = .success(try await page.devTools(method, params: params)) }
                    catch { result = .failure(error) }
                    let waiter = pending.withLock { state in defer { state.waiter = nil }; return state.waiter }
                    if let waiter { waiter.resume(with: result) }
                    else if case .success(let reply) = result, let object = ChromiumPageHostWire.object(reply) {
                        if method == "Runtime.evaluate", let id = (object["result"] as? [String: Any])?["objectId"] as? String {
                            _ = try? await page.devTools("Runtime.releaseObject", params: ["objectId": id])
                        } else if method == "IO.resolveBlob", let uuid = object["uuid"] as? String {
                            _ = try? await page.devTools("IO.close", params: ["handle": "blob:" + uuid])
                        }
                    }
                }
            }
        } onCancel: {
            let waiter = pending.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func close() async {
        ended = true
        let handle = self.handle, objectID = self.objectID
        self.handle = nil
        self.objectID = nil
        let cleanup = Task { [page] in
            if let handle { _ = try? await page.devTools("IO.close", params: ["handle": handle]) }
            if let objectID { _ = try? await page.devTools("Runtime.releaseObject", params: ["objectId": objectID]) }
        }
        if !Task.isCancelled { await cleanup.value }
    }
}
