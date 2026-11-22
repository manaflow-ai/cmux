import Foundation

/// The state of one provider row on the Accounts screen, driven only by
/// ``AccountRowState/reduce(_:)``. Pure value: the UI model feeds events
/// from detection, the user's buttons and CodeRouter replies.
public struct AccountRowState: Sendable, Equatable {
    /// The one operation a row runs at a time.
    public enum Phase: Sendable, Equatable {
        case idle
        case detecting
        /// The provider's own login runs in a terminal or browser tab.
        case reauthenticating
        case connecting
        case removing(accountID: String)
    }

    /// The last operation's outcome, shown under the row until the next one.
    public enum Outcome: Sendable, Equatable {
        case connected
        case removed
        case failed(String)
    }

    public let provider: AIProvider
    public private(set) var detection: ProviderDetection?
    public private(set) var phase: Phase = .detecting
    public private(set) var linked: [LinkedAccount] = []
    public private(set) var outcome: Outcome?
    /// Whether cmux is signed in (CodeRouter acts as that user and team).
    public private(set) var cmuxSignedIn = false
    /// Why CodeRouter's account list could not be read, if it could not.
    public private(set) var codeRouterProblem: String?

    public init(provider: AIProvider) {
        self.provider = provider
    }

    public enum Event: Sendable, Equatable {
        case detectionStarted
        case detected(ProviderDetection)
        case cmuxSignIn(Bool)
        case linkedLoaded([LinkedAccount])
        case linkedFailed(String)
        case reauthStarted
        case reauthEnded
        case connectStarted
        case connectSucceeded([LinkedAccount])
        case connectFailed(String)
        case removeStarted(accountID: String)
        case removeSucceeded([LinkedAccount])
        case removeFailed(String)
    }

    /// Applies one event. Events that do not fit the current phase (a
    /// second Connect while one runs, a stale reply) change nothing.
    public mutating func reduce(_ event: Event) {
        switch event {
        case .detectionStarted:
            if phase == .idle { phase = .detecting }
        case .detected(let result):
            guard result.provider == provider else { return }
            detection = result
            if phase == .detecting || phase == .reauthenticating { phase = .idle }
        case .cmuxSignIn(let signedIn):
            cmuxSignedIn = signedIn
            if !signedIn { linked = []; codeRouterProblem = nil }
        case .linkedLoaded(let accounts):
            linked = accounts.filter { $0.provider == provider }
            codeRouterProblem = nil
        case .linkedFailed(let message):
            codeRouterProblem = message
        case .reauthStarted:
            guard phase == .idle, canReauthenticate else { return }
            phase = .reauthenticating
            outcome = nil
        case .reauthEnded:
            if phase == .reauthenticating { phase = .detecting }
        case .connectStarted:
            guard phase == .idle, canConnect else { return }
            phase = .connecting
            outcome = nil
        case .connectSucceeded(let accounts):
            guard phase == .connecting else { return }
            linked = accounts.filter { $0.provider == provider }
            phase = .idle
            outcome = .connected
        case .connectFailed(let message):
            guard phase == .connecting else { return }
            phase = .idle
            outcome = .failed(message)
        case .removeStarted(let id):
            guard phase == .idle, linked.contains(where: { $0.id == id }) else { return }
            phase = .removing(accountID: id)
            outcome = nil
        case .removeSucceeded(let accounts):
            guard case .removing(let id) = phase else { return }
            linked = accounts.filter { $0.provider == provider && $0.id != id }
            phase = .idle
            outcome = .removed
        case .removeFailed(let message):
            guard case .removing = phase else { return }
            phase = .idle
            outcome = .failed(message)
        }
    }

    // MARK: Derived

    public var status: LocalAuthStatus? { detection?.status }

    public var isBusy: Bool { phase != .idle }

    public var canReauthenticate: Bool { provider.reauthPlan != .none }

    /// Whether CodeRouter can hold this provider at all.
    public var isLinkable: Bool { provider.codeRouterLink != .unsupported }

    /// Connect needs cmux sign-in, a linkable provider and a reachable
    /// CodeRouter. A provider that takes a pasted secret can connect without
    /// a local sign-in.
    public var canConnect: Bool {
        guard cmuxSignedIn, isLinkable, codeRouterProblem == nil else { return false }
        switch provider.codeRouterLink {
        case .claudeOAuthToken, .apiKey, .anthropicAPIKey: return true
        case .codexOAuth: return status == .signedIn
        case .bedrockKeys: return hasBedrockKeys
        case .unsupported: return false
        }
    }

    /// Bedrock Connect sends AWS keys from the shell; a profile alone is not enough.
    public var hasBedrockKeys: Bool {
        let sources = detection?.sources ?? []
        return Self.bedrockKeyNames.allSatisfy { sources.contains(.environment($0)) }
    }

    public static let bedrockKeyNames = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"]

    /// Whether Connect must first ask for a secret (no local one to send).
    public var connectNeedsPaste: Bool {
        switch provider.codeRouterLink {
        case .claudeOAuthToken: !(detection?.sources.contains(.environment("CLAUDE_CODE_OAUTH_TOKEN")) ?? false)
        case .apiKey, .anthropicAPIKey: status != .signedIn
        case .codexOAuth, .bedrockKeys, .unsupported: false
        }
    }
}
