/// The permission card as text for text-only hosts (``CookieImportTextCard``).
extension CookieImportAsk {
    /// The card as text and buttons for this phase.
    public var textCard: CookieImportTextCard {
        let text = CookieImportCardText(request, phase: phase, isArmed: isArmed, showsSites: showsSites,
                                        deadlineSeconds: Int(limit.components.seconds))
        let actions = text.buttons.filter(\.isEnabled).map { CookieImportTextCard.Action(id: $0.id.rawValue, title: $0.title) }
        return CookieImportTextCard(text: text.plainText, actions: actions, isAsking: phase.isAsking)
    }

    /// Runs the button `id` of ``textCard`` (an unknown id does nothing).
    public func perform(_ id: String) {
        guard let action = CookieImportCardAction(rawValue: id) else { return }
        CookieImportCardView.perform(action, on: self)
    }
}
