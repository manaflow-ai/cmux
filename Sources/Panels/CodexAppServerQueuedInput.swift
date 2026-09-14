import Foundation

struct CodexAppServerQueuedInput {
    let text: String
    let permissionMode: AgentSessionPermissionMode
    let modelID: String?
    let reasoningEffort: String?
    let continuation: CheckedContinuation<Void, Error>

    func resume() {
        continuation.resume()
    }

    func resume(throwing error: Error) {
        continuation.resume(throwing: error)
    }
}
