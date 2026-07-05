import Foundation

enum AgentSessionBridgeError: LocalizedError {
    case invalidRequest
    case invalidProvider(String)
    case missingParameter(String)
    case unsupportedMethod(String)
    case sessionNotFound(String)
    case sessionAlreadyRunning
    case providerNotReady(String)
    case unsupportedTransport(String)

    var code: String {
        switch self {
        case .invalidRequest:
            return "invalidRequest"
        case .invalidProvider:
            return "invalidProvider"
        case .missingParameter:
            return "missingParameter"
        case .unsupportedMethod:
            return "unsupportedMethod"
        case .sessionNotFound:
            return "sessionNotFound"
        case .sessionAlreadyRunning:
            return "sessionAlreadyRunning"
        case .providerNotReady:
            return "providerNotReady"
        case .unsupportedTransport:
            return "unsupportedTransport"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return String(localized: "agentSession.bridge.error.invalidRequest", defaultValue: "Invalid bridge request.")
        case .invalidProvider(let provider):
            _ = provider
            return String(
                localized: "agentSession.bridge.error.invalidProvider",
                defaultValue: "The selected provider is unavailable."
            )
        case .missingParameter(let parameter):
            _ = parameter
            return String(
                localized: "agentSession.bridge.error.missingParameter",
                defaultValue: "The request is incomplete."
            )
        case .unsupportedMethod(let method):
            _ = method
            return String(
                localized: "agentSession.bridge.error.unsupportedMethod",
                defaultValue: "This action is not supported."
            )
        case .sessionNotFound(let sessionId):
            _ = sessionId
            return String(
                localized: "agentSession.bridge.error.sessionNotFound",
                defaultValue: "The agent session is no longer available."
            )
        case .sessionAlreadyRunning:
            return String(
                localized: "agentSession.bridge.error.sessionAlreadyRunning",
                defaultValue: "An agent session is already running."
            )
        case .providerNotReady(let provider):
            _ = provider
            return String(
                localized: "agentSession.bridge.error.providerNotReady",
                defaultValue: "The provider is not ready yet."
            )
        case .unsupportedTransport(let transport):
            _ = transport
            return String(
                localized: "agentSession.bridge.error.unsupportedTransport",
                defaultValue: "Agent transport is not supported."
            )
        }
    }
}
