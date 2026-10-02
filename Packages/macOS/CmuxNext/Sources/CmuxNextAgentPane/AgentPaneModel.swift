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
    /// Saves the inspector's exported log (text, suggested file name) where
    /// the user picks; true when saved, false when the user cancelled. Nil
    /// leaves the page to copy the log instead.
    @ObservationIgnored public var onSaveLog: (@MainActor (String, String) async throws -> Bool)?

    @ObservationIgnored private let host: any AgentPaneHostProviding

    public init(host: any AgentPaneHostProviding, sessionId: String? = nil) {
        self.host = host
        self.sessionId = sessionId
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .ready, .reconnect:
            do {
                let handshake = request == .ready
                    ? try await host.handshake(sessionId: sessionId)
                    : try await host.reconnectHandshake(sessionId: sessionId)
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
        case .saveLog(let text, let suggestedName):
            // The page copies the log instead on any failure, so these messages
            // are diagnostics, like the unsupported one below.
            guard let onSaveLog else { return AgentPaneReply.failure(code: "unsupported", message: "Saving the log is unavailable") }
            do {
                return AgentPaneReply.success(try await onSaveLog(text, suggestedName))
            } catch {
                return AgentPaneReply.failure(code: "save_failed", message: "Could not save the log: \(error.localizedDescription)")
            }
        case .unsupported(let method):
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
        }
    }
}
