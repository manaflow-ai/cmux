public import CmuxNextSettings
public import Foundation

/// A card a cmux tool raises in a chat, above its composer, beside the chat's permission asks
/// (cmuxterm-hq#1874 slice 5): an agent's Move to Cloud waits on it for the person's answer.
/// The App owns each card and its text, already in the user's language; the page draws it as it
/// comes (`toolCards` event, toolCardStore.ts) and sends a click back as `chat.toolCard.respond
/// {id, action}`, which the host takes only with a real gesture in the pane. A card may have one
/// text field (``Input``, a secret the person types or pastes): its value comes as `value`, only
/// with a button that ``Action/submitsInput``, and is handed on as ``Entered``, which never prints.
public nonisolated struct AgentPaneToolCard: Hashable, Sendable {
    public enum State: String, Sendable {
        /// Waiting on the person's answer.
        case ask
        /// Answered; the work it started is running.
        case working
        /// The work it started is done; ``text`` says what it made, and an action may open it.
        case done
        /// The work stopped; ``text`` says why.
        case failed
    }

    /// One button.
    public struct Action: Hashable, Sendable {
        public var id: String
        public var title: String
        /// The button's tooltip.
        public var hint: String?
        /// The button sends the card's field (``Input``), and only with a value in it.
        public var submitsInput: Bool

        public init(id: String, title: String, hint: String? = nil, submitsInput: Bool = false) {
            self.id = id
            self.title = title
            self.hint = hint
            self.submitsInput = submitsInput
        }
    }

    /// The card's text field. The page draws a secure one as a password field and keeps its
    /// value only until the click that sends it.
    public struct Input: Hashable, Sendable {
        public var placeholder: String
        public var secure: Bool
        /// The longest value taken, in UTF-8 bytes.
        public var maximumBytes: Int

        public init(placeholder: String, secure: Bool, maximumBytes: Int) {
            self.placeholder = placeholder
            self.secure = secure
            self.maximumBytes = min(maximumBytes, AgentPaneToolCard.maximumInputBytes)
        }
    }

    /// What the person typed in a card's field: its description, debug description and mirror never
    /// show it, so no log line, reply or `String(describing:)` of a request can carry it.
    public struct Entered: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let text: String

        public init(_ text: String) { self.text = text }

        public var description: String { "<entered>" }
        public var debugDescription: String { "<entered>" }
        public var customMirror: Mirror { Mirror(self, children: [:]) }
    }

    public var id: String
    public var state: State
    public var text: String
    public var actions: [Action]
    public var input: Input?

    public init(id: String, state: State, text: String, actions: [Action], input: Input? = nil) {
        self.id = id
        self.state = state
        self.text = text
        self.actions = actions
        self.input = input
    }

    /// The most cards one chat shows.
    public static let maximumShown = 4
    /// The longest value any field takes, in UTF-8 bytes.
    public static let maximumInputBytes = 64 * 1024

    var json: JSONValue {
        let actions = actions.map { action -> JSONValue in
            var object: [String: JSONValue] = ["id": .string(action.id), "title": .string(action.title)]
            if let hint = action.hint { object["hint"] = .string(hint) }
            if action.submitsInput { object["submitsInput"] = .bool(true) }
            return .object(object)
        }
        var object: [String: JSONValue] = ["id": .string(id), "state": .string(state.rawValue), "text": .string(text), "actions": .array(actions)]
        if let input {
            object["input"] = ["placeholder": .string(input.placeholder), "secure": .bool(input.secure), "maxBytes": .number(Double(input.maximumBytes))]
        }
        return .object(object)
    }

    /// `chat.toolCard.respond {id, action, value?}`: the card, button and typed value, nil when the
    /// params break the contract.
    static func answer(_ params: [String: Any]?) -> (card: String, action: String, value: Entered?)? {
        guard let params, Set(params.keys) == ["id", "action"] || Set(params.keys) == ["id", "action", "value"],
              let card = params["id"] as? String, let action = params["action"] as? String,
              !card.isEmpty, card.utf8.count <= 128, !action.isEmpty, action.utf8.count <= 64 else { return nil }
        guard let raw = params["value"] else { return (card, action, nil) }
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= maximumInputBytes else { return nil }
        return (card, action, Entered(value))
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
    /// (page script cannot make one), then the App's answer (``AgentPaneModel/onToolCard``). A value
    /// goes only with a button that sends the card's field, and such a button needs one.
    @MainActor static func respond(card: String, action: String, value: Entered?, in model: AgentPaneModel) -> [String: Any] {
        guard let onToolCard = model.onToolCard, let shown = model.toolCards.first(where: { $0.id == card }),
              let button = shown.actions.first(where: { $0.id == action }) else {
            return AgentPaneModel.unsupported("chat.toolCard.respond")
        }
        if button.submitsInput {
            guard let input = shown.input, let value else { return AgentPaneReply.failure(code: "input_required", message: "Enter a value first") }
            guard value.text.utf8.count <= input.maximumBytes else { return AgentPaneReply.failure(code: "input_too_long", message: "The value is too long") }
        } else if value != nil {
            return AgentPaneModel.unsupported("chat.toolCard.respond")
        }
        guard model.transport.gestures.consume() else { return AgentPaneModel.transportFailure(.gestureRequired) }
        onToolCard(card, action, value)
        return AgentPaneReply.success()
    }
}
