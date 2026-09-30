import Foundation

struct CodexAppServerQueuedInput {
    let text: String
    let permissionMode: AgentSessionPermissionMode
    let continuation: CheckedContinuation<Void, Error>

    func resume() {
        continuation.resume()
    }

    func resume(throwing error: Error) {
        continuation.resume(throwing: error)
    }
}
