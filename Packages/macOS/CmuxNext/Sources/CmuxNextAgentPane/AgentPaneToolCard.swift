public import CmuxNextSettings
public import Foundation

/// A card a cmux tool raises in a chat, above its composer, beside the chat's permission asks
/// (cmuxterm-hq#1874 slice 5): an agent's Move to Cloud waits on it for the person's answer.
/// The App owns each card and its text, already in the user's language; the page draws it as it
/// comes (`toolCards` event, toolCardStore.ts) and sends a click back as `chat.toolCard.respond
/// {id, action}`, which the host takes only with a real gesture in the pane.
public nonisolated struct AgentPaneToolCard: Hashable, Sendable {
    public enum State: String, Sendable {
        /// Waiting on the person's answer.
        case ask
        /// Answered; the work it started is running.
        case working
        /// The work stopped; ``text`` says why.
        case failed
    }

    /// One button.
    public struct Action: Hashable, Sendable {
        public var id: String
        public var title: String
        /// The button's tooltip.
        public var hint: String?

        public init(id: String, title: String, hint: String? = nil) {
            self.id = id
            self.title = title
            self.hint = hint
        }
    }

    public var id: String
    public var state: State
    public var text: String
    public var actions: [Action]

    public init(id: String, state: State, text: String, actions: [Action]) {
        self.id = id
        self.state = state
        self.text = text
        self.actions = actions
    }

    /// The most cards one chat shows.
    public static let maximumShown = 4

    var json: JSONValue {
        let actions = actions.map { action -> JSONValue in
            var object: [String: JSONValue] = ["id": .string(action.id), "title": .string(action.title)]
            if let hint = action.hint { object["hint"] = .string(hint) }
            return .object(object)
        }
        return ["id": .string(id), "state": .string(state.rawValue), "text": .string(text), "actions": .array(actions)]
    }

    /// `chat.toolCard.respond {id, action}`: the card and button, nil when the params break the contract.
    static func answer(_ params: [String: Any]?) -> (card: String, action: String)? {
        guard let params, Set(params.keys) == ["id", "action"], let card = params["id"] as? String, let action = params["action"] as? String,
              !card.isEmpty, card.utf8.count <= 128, !action.isEmpty, action.utf8.count <= 64 else { return nil }
        return (card, action)
    }
}

extension AgentPageEvent {
    /// The chat's tool cards (`toolCards`).
    public static func toolCards(_ cards: [AgentPaneToolCard]) -> AgentPageEvent {
        AgentPageEvent(kind: "toolCards", value: .array(cards.prefix(AgentPaneToolCard.maximumShown).map(\.json)))
    }
}

extension AgentPaneToolCard {
    /// Shows `cards` on `view`'s page (a change only); the model keeps them for a page that loads later.
    /// Not an AgentPaneView extension: that type is at its size limit.
    @MainActor public static func show(_ cards: [AgentPaneToolCard], on view: AgentPaneView) {
        guard cards != view.model.toolCards else { return }
        view.model.toolCards = cards
        replay(to: view)
    }

    /// Gives `view`'s page the cards its model keeps (a page that just loaded).
    @MainActor static func replay(to view: AgentPaneView) {
        let event = AgentPageEvent.toolCards(view.model.toolCards)
        view.deliver([event], scripts: ["window.cmuxAcpmuxToolCards?.(\(event.value.compactText));"])
    }

    /// The reply to the page's click on `action` of card `card`: only with a real gesture in the pane
    /// (page script cannot make one), then the App's answer (``AgentPaneModel/onToolCard``).
    @MainActor static func respond(card: String, action: String, in model: AgentPaneModel) -> [String: Any] {
        guard let onToolCard = model.onToolCard, model.toolCards.contains(where: { $0.id == card && $0.actions.contains { $0.id == action } }) else {
            return AgentPaneModel.unsupported("chat.toolCard.respond")
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        onToolCard(card, action)
        return AgentPaneReply.success()
    }
}
