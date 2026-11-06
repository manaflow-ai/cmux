import Foundation

/// One path for "New Agent Chat" from outside the app (the Shortcuts action, Siri,
/// Spotlight, the Action Button): the phone's form of the Mac's Start Agent from Any App
/// (its quick composer). The signed-in shell installs ``handler``: a new agent chat on the
/// Mac new workspaces go to, in its most recent folder, with `prompt` in its composer. A
/// start asked for before the shell is up (a cold launch) waits for it, briefly.
@MainActor
public final class AgentChatLauncher {
    public static let shared = AgentChatLauncher()

    /// Starts the chat; set by the shell while it is on screen.
    public var handler: (@MainActor (_ prompt: String?) -> Void)? {
        didSet {
            guard let handler, let pending else { return }
            self.pending = nil
            // Only one asked for moments ago: never a chat that appears minutes later, after sign-in.
            guard now().timeIntervalSince(pending.at) < Self.pendingWindow else { return }
            handler(pending.prompt)
        }
    }

    private var pending: (prompt: String?, at: Date)?
    private let now: () -> Date
    static let pendingWindow: TimeInterval = 20

    public init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    public func start(prompt: String?) {
        let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let handler else {
            pending = (prompt, now())
            return
        }
        handler(prompt)
    }

    /// Drops a start asked for while signed out.
    public func cancelPending() {
        pending = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
