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

    @ObservationIgnored private let host: any AgentPaneHostProviding

    public init(host: any AgentPaneHostProviding, sessionId: String? = nil) {
        self.host = host
        self.sessionId = sessionId
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .ready:
            do {
                let handshake = try await host.handshake(sessionId: sessionId)
                lastError = nil
                return AgentPaneReply.handshake(handshake)
            } catch {
                let message = AgentPaneStrings.message(for: error)
                lastError = message
                return AgentPaneReply.failure(code: "host_unavailable", message: message)
            }
        case .persistSession(let id):
            if id != sessionId {
                sessionId = id
                onSessionChange?(id)
            }
            return AgentPaneReply.success()
        case .unsupported(let method):
            return AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
        }
    }
}
