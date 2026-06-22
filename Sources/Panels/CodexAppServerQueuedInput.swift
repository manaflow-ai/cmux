import Foundation

struct CodexAppServerQueuedInput {
    let text: String
    let permissionMode: AgentSessionPermissionMode
    let continuation: CheckedContinuation<Void, Error>?

    init(
        text: String,
        permissionMode: AgentSessionPermissionMode,
        continuation: CheckedContinuation<Void, Error>? = nil
    ) {
        self.text = text
        self.permissionMode = permissionMode
        self.continuation = continuation
    }

    func resume() {
        continuation?.resume()
    }

    func resume(throwing error: Error) {
        continuation?.resume(throwing: error)
    }
}
