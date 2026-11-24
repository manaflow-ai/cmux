/// Where an unhealthy part is on screen, in the person's words: the chat a page shows and the workspace it is in,
/// and the way to go there (David Beyer, 2026-11-20: "Agent chat needs a repair" did not say which chat).
/// The App resolves it (``AppHealthPlaces``) only when a line or the card is drawn, never on a heartbeat.
@MainActor
public struct AppHealthPlace {
    /// The chat's title as its tab shows it; nil when it has none yet.
    public var chat: String?
    /// The workspace's name as its sidebar row shows it; nil outside a workspace (Home's dock, a floating chat).
    public var workspace: String?
    /// Shows the chat: its window forward, its workspace and tab selected (the card's Show chat).
    public var reveal: @MainActor () -> Void

    /// - Parameters:
    ///   - chat: The chat's shown title, nil when it has none.
    ///   - workspace: The shown name of the workspace that holds it, nil outside one.
    ///   - reveal: Brings the chat in front of the person.
    public init(chat: String?, workspace: String?, reveal: @escaping @MainActor () -> Void) {
        self.chat = chat
        self.workspace = workspace
        self.reveal = reveal
    }
}
