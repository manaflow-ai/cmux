#if DEBUG
import Foundation

/// DEBUG ONLY: the playground's phase picker; ``apply(to:tools:)`` walks a fresh flow to the phase
/// through the flow's own steps, so the playground never shows a state the flow cannot reach.
public enum McpConnectPlaygroundPhase: Int, CaseIterable, Sendable {
    case ask, enterKey, signingIn, connecting, connected, declined, failed

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .enterKey: "Enter key"
        case .signingIn: "Signing in"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .declined: "Declined"
        case .failed: "Failed"
        }
    }

    func apply(to flow: inout McpConnectCardFlow, tools: [McpConnectCard.Tool]) {
        switch self {
        case .ask: return
        case .declined: _ = flow.cancel()
        case .failed:
            _ = flow.connect()
            flow.failed("the server’s metadata names another resource")
        case .enterKey, .signingIn, .connecting, .connected:
            _ = flow.connect()
            if self == .enterKey { return }
            if flow.phase == .enterKey { _ = flow.submit(McpConnectKey("ctx7sk-demo")) }
            if self == .signingIn { return }
            flow.signedIn()
            if self == .connecting { return }
            flow.connected(tools)
        }
    }
}
#endif
