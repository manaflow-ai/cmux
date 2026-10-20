/// Where a design mode card goes (plans/cmux-next/design-mode-DESIGN.md).
public nonisolated enum BrowserDesignModeDelivery: Sendable, Equatable {
    /// A variation pick: sent to the shown Home chat as this message, at once.
    case sendToHome(String)
    /// Added to the shown Home composer, to go with the next message.
    case attachToHome
    /// Added to the workspace's last-used agent chat composer.
    case agentChat
    /// No chat can take it.
    case nowhere

    /// The delivery for `card` given what the browser's window shows.
    public init(_ card: BrowserDesignModeCard, homeShown: Bool, agentChat: Bool) {
        if homeShown {
            let firstLine = card.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            self = card.pickedVariation != nil && !firstLine.isEmpty ? .sendToHome(firstLine) : .attachToHome
        } else {
            self = agentChat ? .agentChat : .nowhere
        }
    }
}
