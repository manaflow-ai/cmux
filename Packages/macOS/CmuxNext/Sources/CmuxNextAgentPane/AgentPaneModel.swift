public import Foundation
public import Observation

/// One agent pane's host-side state: which acpmux session it shows. The
/// session, its transcript and every chat action live in acpmux and the
/// page; this only answers the page's host requests.
@Observable
public final class AgentPaneModel {
    /// The session the page last reported, nil for a new chat that has not
    /// sent its first prompt.
    public private(set) var sessionId: String?
    /// The last handshake failure shown to the page, for diagnostics.
    public private(set) var lastError: String?

    /// Called when the page switches to or creates a session, so the App can
    /// keep it with the tab.
    @ObservationIgnored public var onSessionChange: ((String) -> Void)?
    /// Gets each settled transcript scroll's frame intervals (milliseconds).
    @ObservationIgnored public var onFramePacing: (([Double]) -> Void)?
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?
    /// Opens a changed file the page names; false when it could not.
    @ObservationIgnored public var onOpenFile: (@MainActor (URL, AgentPaneFileTarget) async -> Bool)?
    /// Runs a git read on the session host and returns its JSON result.
    /// Throws an ``AgentPaneGitFailure`` saying who failed; any other error
    /// reaches the page as `native.failed`.
    @ObservationIgnored public var onGit: (@MainActor (AgentPaneGitRequest) async throws -> Data)?

    @ObservationIgnored private let host: any AgentPaneHostProviding
    /// What a new chat inherits from the tab it was opened from.
    @ObservationIgnored private let seed: AgentPaneSeedSource?

    public init(host: any AgentPaneHostProviding, sessionId: String? = nil, seed: AgentPaneSeedSource? = nil) {
        self.host = host
        self.sessionId = sessionId
        self.seed = seed
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .ready, .reconnect:
            do {
                var handshake = request == .ready
                    ? try await host.handshake(sessionId: sessionId)
                    : try await host.reconnectHandshake(sessionId: sessionId)
                // Only a chat without a session yet starts from the seed.
                if sessionId == nil, let seed = await seed?.take() {
                    handshake.cwd = seed.cwd
                    handshake.draft = seed.draft
                }
                lastError = nil
                return AgentPaneReply.handshake(handshake)
            } catch {
                let message = AgentPaneHostError.userMessage(for: error)
                lastError = message
                return AgentPaneReply.failure(code: "host_unavailable", message: message)
            }
        case .persistSession(let id):
            if id != sessionId {
                sessionId = id
                onSessionChange?(id)
            }
            return AgentPaneReply.success()
        case .framePacing(let intervals):
            onFramePacing?(intervals)
            return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .openFile(let path, let target):
            guard let onOpenFile, let url = AgentPaneFileOpen.resolve(path),
                  target == .editor || AgentPaneFileOpen.showsInTab(url), await onOpenFile(url, target) else {
                return AgentPaneReply.failure(code: "open_failed", message: Self.openFileFailedMessage)
            }
            return AgentPaneReply.success()
        case .git(let git):
            guard let onGit else { return Self.gitFailure(.notConnected) }
            do {
                let data = try await onGit(git)
                guard let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    return Self.gitFailure(.failed)
                }
                return AgentPaneReply.success(value)
            } catch {
                return Self.gitFailure(error as? AgentPaneGitFailure ?? .failed)
            }
        case .invalidGit:
            return Self.gitFailure(.invalidRequest)
        case .unsupported(let method):
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
        }
    }
}

extension AgentPaneModel {
    /// The page's reply for a failed git read: the failure's code, origin,
    /// details and retryable under the localized text.
    static func gitFailure(_ failure: AgentPaneGitFailure) -> [String: Any] {
        let details = failure.details.flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        return AgentPaneReply.failure(
            code: failure.code, message: gitFailedMessage, details: details,
            retryable: failure.retryable, origin: failure.origin.rawValue)
    }
}
