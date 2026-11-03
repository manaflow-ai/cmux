public import Foundation

nonisolated public enum CloudCodexBrokerError: Error, LocalizedError, Sendable, Equatable {
    case consentRequired
    case scopeChanged
    case sharedMachine
    case unsupportedMachine
    case brokerUnavailable
    case notAuthenticated
    case loginRequired(CloudCodexLoginPrompt)
    case invalidReply
    case accountChanged
    case expiredAccess
    case targetOffline
    case remoteDeliveryFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .consentRequired: "Confirm that Codex access will be delivered to this VM."
        case .scopeChanged: "The signed-in account or team changed; start the transfer again."
        case .sharedMachine: "This VM is shared, so it cannot receive a personal Codex credential."
        case .unsupportedMachine: "This VM does not support Codex access delivery yet."
        case .brokerUnavailable: "The local Codex sign-in holder is unavailable."
        case .notAuthenticated: "Finish signing in to Codex to continue."
        case .loginRequired: "Sign in to Codex to continue."
        case .invalidReply, .accountChanged: "Codex sign-in could not be completed."
        case .expiredAccess: "Codex returned an expired access token."
        case .targetOffline: "This VM is offline or paused; resume it before delivering Codex access."
        case .remoteDeliveryFailed: "The Codex access token could not be delivered to this VM."
        case .cancelled: "Codex sign-in was cancelled."
        }
    }
}

