import CmuxHomeCore
import CmuxNextCloud
import CmuxNextDaemon
public import CmuxNextHomeModel

/// A headless New Chief run's outcome (`home.newChief` from the CLI or MCP): the exact record it made, or why not.
public enum HomeActionChiefResult {
    /// The Chief this run created.
    case success(HomeChiefRecord)
    /// The run made no Chief.
    case failure(HomeComposeOutcome)

    /// What the New Chief sheet and button show: the made Chief's conversation, or why none was made.
    public var outcome: HomeComposeOutcome {
        switch self {
        case .success(let record): record.mainConversation.map { HomeComposeOutcome.opened(ConversationID($0)) } ?? .invited(nil)
        case .failure(let outcome): outcome
        }
    }

    /// A New Chief that threw `error`: on this Mac's Chief owner (`chief.profile.create`, a
    /// ``DaemonError``) or on the cloud `chief.create` (a `FeedServiceError`), as the person reads it.
    public static func failed(_ error: any Error, onThisMac: Bool) -> HomeActionChiefResult {
        switch error {
        case DaemonError.notConnected, DaemonError.connectionClosed, DaemonError.daemonShutdown, FeedServiceError.signedOut:
            .failure(.offline)
        case DaemonError.command(_, let message, let code, _, _): .failure(.refused(message.isEmpty ? code ?? "" : message))
        case let error as DaemonError: .failure(.refused(error.description))
        case FeedServiceError.owner(let code, let message):
            .failure(code == "policy.denied" || code == "validation.invalid" ? .refused(message) : .refusal(code: code))
        default: .failure(.refused(onThisMac ? String(describing: error) : ""))
        }
    }
}
