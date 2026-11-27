/// How the app's Share with Me went (`machine.share.self`): the person now starts chats on the
/// machine, or the Cloud API refused, with its `error` code (the page keys its card on it,
/// webviews machineShare.ts) and a localized line.
public enum AgentPaneMachineShare: Equatable, Sendable {
    case shared
    case refused(code: String, message: String)
}

extension AgentPaneModel {
    /// Share with Me on a teammate's Cloud machine's refused start: a remote chat only, and only on
    /// a real gesture (it changes who may use the machine, so page script cannot make one): the page
    /// host's authenticated click (`userGesture`), or the legacy bridge's gesture credit.
    func shareMachineWithMe(userGesture: Bool = false) async -> [String: Any] {
        guard remoteChat, let onShareMachineWithMe else { return Self.unsupported("machine.share.self") }
        guard userGesture || transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        switch await onShareMachineWithMe() {
        case .shared: return AgentPaneReply.success(["shared": true])
        case .refused(let code, let message): return AgentPaneReply.failure(code: code, message: message)
        }
    }
}
