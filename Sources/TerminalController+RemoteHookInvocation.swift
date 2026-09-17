import CmuxSettings
import Foundation

extension TerminalController {
    nonisolated func v2RemoteHookInvocation(method: String, params: [String: Any]) -> V2CallResult {
        switch RemoteHookInvocationBridge().handle(
            method: method,
            params: params,
            localSocketPath: activeSocketPath(preferredPath: SocketControlSettings.socketPath())
        ) {
        case .success(let payload):
            return .ok(payload)
        case .failure(let error):
            return .err(code: error.code, message: error.message, data: nil)
        }
    }
}
