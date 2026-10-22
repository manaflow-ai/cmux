/// The permission card as text and buttons, for a host that draws only that (an agent chat's
/// tool card): the same words as ``CookieImportCardView``. Built by ``CookieImportAsk/textCard``.
public struct CookieImportTextCard: Sendable, Equatable {
    /// One button: its id (``CookieImportAsk/perform(_:)``) and title.
    public struct Action: Sendable, Equatable {
        public var id: String
        public var title: String
    }

    /// The card's text, one fact per line.
    public var text: String
    /// The buttons that work now (Allow Once only once the card is armed).
    public var actions: [Action]
    /// Whether the card still waits for the person's answer.
    public var isAsking: Bool
}
