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
    /// The new tab page this pane shows until it has a session, nil for a
    /// plain chat. Cleared once the page reports a session.
    public private(set) var newTab: AgentPaneNewTab?
    /// The new tab page chose a terminal or browser (`tab.open`).
    @ObservationIgnored public var onOpenTab: ((AgentPaneTabKind, String, String?) -> Void)?
    /// The location bar picked an open tab or workspace (`tab.jump`).
    @ObservationIgnored public var onJump: ((AgentPaneJumpTarget, String) -> Void)?
    /// The new tab page asked to change a kind's shortcut.
    @ObservationIgnored public var onEditShortcut: ((AgentPaneTabKind) -> Void)?
    /// Gets the composer's dictation requests (the pane's mic).
    @ObservationIgnored public var onDictation: ((AgentPaneDictationCommand) -> Void)?

    @ObservationIgnored private let host: any AgentPaneHostProviding

    public init(host: any AgentPaneHostProviding, sessionId: String? = nil, newTab: AgentPaneNewTab? = nil) {
        self.host = host
        self.sessionId = sessionId
        self.newTab = sessionId == nil ? newTab : nil
    }

    /// The reply for one page request.
    public func respond(to request: AgentPaneRequest) async -> [String: Any] {
        switch request {
        case .ready, .reconnect:
            do {
                var handshake = request == .ready
                    ? try await host.handshake(sessionId: sessionId)
                    : try await host.reconnectHandshake(sessionId: sessionId)
                // A new tab page is a new chat on every host, the mock included: the page
                // never falls back to the most recent session behind it.
                if sessionId == nil, let newTab {
                    handshake.newTab = newTab
                    handshake.newSession = true
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
                newTab = nil
                onSessionChange?(id)
            }
            return AgentPaneReply.success()
        case .framePacing(let intervals):
            onFramePacing?(intervals)
            return AgentPaneReply.success()
        case .openTab(let kind, let text, let cwd):
            guard newTab != nil, let onOpenTab else { return Self.unsupported("tab.open") }
            onOpenTab(kind, text, cwd)
            return AgentPaneReply.success()
        case .jump(let target, let id):
            guard newTab != nil, let onJump else { return Self.unsupported("tab.jump") }
            onJump(target, id)
            return AgentPaneReply.success()
        case .editShortcut(let kind):
            guard let onEditShortcut else { return Self.unsupported("shortcut.edit") }
            onEditShortcut(kind)
            return AgentPaneReply.success()
        case .dictation(let command):
            guard let onDictation else { return AgentPaneReply.failure(code: "unsupported", message: "Dictation is unavailable") }
            onDictation(command)
            return AgentPaneReply.success()
        case .unsupported(let method):
            return Self.unsupported(method)
        }
    }

    private static func unsupported(_ method: String) -> [String: Any] {
        AgentPaneReply.failure(code: "unsupported", message: "Unsupported agent pane request: \(method)")
    }
}
