import Foundation

enum AgentSessionBridgeContract {
    static let handlerName = "agentSession"
}

func agentSessionIsLoopbackURL(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
}
