public import AppKit

/// The confirmation of one team invite from the CLI, MCP or an agent: a
/// glass panel centered on a cmux window (a child window, so it stays above
/// page windows), shown before cmux.com is asked to send anything. It names
/// who asked (its chat or terminal tab; a click reveals it), the reason, the
/// addresses, the team and the role, and warns that an accepted invite can
/// raise the team's bill. Non-activating: showing it never takes the
/// person's focus (socket focus policy). Don't Send, Escape and the time
/// limit send nothing.
@MainActor
public final class TeamInviteConsentPanel: TeamInviteConsenting {
    static let accessibilityID = "app.teamInviteConsent"
    /// How long the panel waits for an answer before it declines.
    public static let limit: Duration = .seconds(180)

    private let window: @MainActor () -> NSWindow?
    private let reveal: @MainActor (String) -> Void
    private var shown: TeamInviteConsentWindow?

    /// Creates the confirmation.
    ///
    /// - Parameters:
    ///   - window: The cmux window to show the panel on, nil when cmux has none (the run is then declined).
    ///   - reveal: Reveals the requester's tab by id, as the person's click.
    public init(window: @escaping @MainActor () -> NSWindow?, reveal: @escaping @MainActor (String) -> Void) {
        self.window = window
        self.reveal = reveal
    }

    /// Whether a confirmation is up now.
    public var isAsking: Bool { shown != nil }

    /// Shows the panel and returns the person's answer (``TeamInviteAnswer/deny`` with no window or while another is up).
    public func ask(_ request: TeamInviteRequest) async -> TeamInviteAnswer {
        guard shown == nil, let parent = window() else { return .deny }
        let reveal = self.reveal
        let shown = TeamInviteConsentWindow(request: request, onShowRequester: request.requester.tabID.map { tab in { reveal(tab) } })
        self.shown = shown
        let answer = await shown.ask(on: parent, limit: Self.limit)
        self.shown = nil
        return answer
    }
}
