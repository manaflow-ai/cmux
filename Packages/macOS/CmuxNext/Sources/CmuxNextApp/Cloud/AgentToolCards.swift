import CmuxNextAgentPane

/// The tool cards cmux raises in chats (``AgentPaneToolCard``, cmuxterm-hq#1874 slice 5), by the
/// chat's tab: each owner (Move to Cloud's ask, ``CloudMoveAsks``) sets its own cards on a tab and
/// answers clicks on them. The chat's page shows every owner's cards; a chat with no page yet gets
/// one made (``view``), as when it is first shown.
@MainActor
final class AgentToolCards {
    /// A click: the card, the button and what the person typed in the card's field (only for a button that sends it).
    typealias Answer = @MainActor (_ card: String, _ action: String, _ value: AgentPaneToolCard.Entered?) -> Void

    private struct Entry {
        var cards: [AgentPaneToolCard]
        var answer: Answer
    }

    /// Owner to entry, by tab.
    private var byTab: [String: [String: Entry]] = [:]
    /// The chat page of a tab, made if it has none and `make` (the App's agent tabs); nil when there is none.
    var view: @MainActor (_ tab: String, _ make: Bool) -> AgentPaneView? = { _, _ in nil }

    /// Sets `owner`'s cards on chat tab `tab` (none removes them), each click going to `answer`.
    /// False when the chat has no page to show them.
    @discardableResult
    func set(_ cards: [AgentPaneToolCard], owner: String, tab: String, answer: @escaping Answer) -> Bool {
        var owners = byTab[tab] ?? [:]
        owners[owner] = cards.isEmpty ? nil : Entry(cards: cards, answer: answer)
        byTab[tab] = owners.isEmpty ? nil : owners
        return push(tab)
    }

    /// Shows chat tab `tab`'s cards again, on its current page; false when it has none to show them.
    func reshow(tab: String) -> Bool { push(tab) }

    /// Every card on chat tab `tab`, in owner order.
    func cards(tab: String) -> [AgentPaneToolCard] {
        let owners = byTab[tab] ?? [:]
        return owners.keys.sorted().flatMap { owners[$0]?.cards ?? [] }
    }

    private func push(_ tab: String) -> Bool {
        let shown = cards(tab: tab)
        guard let view = view(tab, !shown.isEmpty) else { return shown.isEmpty }
        view.model.onToolCard = { [weak self] card, action, value in self?.answer(tab: tab, card: card, action: action, value: value) }
        AgentPaneToolCard.show(shown, on: view)
        return true
    }

    private func answer(tab: String, card: String, action: String, value: AgentPaneToolCard.Entered?) {
        guard let entry = byTab[tab]?.values.first(where: { $0.cards.contains { $0.id == card } }) else { return }
        entry.answer(card, action, value)
    }
}
