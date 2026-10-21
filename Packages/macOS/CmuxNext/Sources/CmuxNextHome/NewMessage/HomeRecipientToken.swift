/// One token of New Message's To: field: what the person typed, and the
/// recipient it stands for. A token with no recipient (a name nobody has,
/// an address that does not parse) draws red, as in Messages, and blocks
/// the send until it is removed or fixed.
public struct HomeRecipientToken: Hashable, Sendable {
    /// The text the token shows (a person's name, or the typed address).
    public var text: String
    /// The recipient it stands for; nil when the text names nobody.
    public var recipient: HomeRecipient?

    /// Creates a token.
    /// - Parameters:
    ///   - text: The shown text.
    ///   - recipient: The recipient, or nil for an invalid token.
    public init(text: String, recipient: HomeRecipient?) {
        self.text = text
        self.recipient = recipient
    }

    /// A token for a recipient chosen from the suggestions.
    public init(_ recipient: HomeRecipient) {
        self.init(text: recipient.label, recipient: recipient)
    }

    /// False draws the token red (Messages' unknown-recipient token).
    public var isValid: Bool { recipient != nil }
}
