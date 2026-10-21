public import CmuxNextSettings
public import Foundation

/// The import suggestion cards on the New Tab page: what this Mac has that cmux can bring
/// over (CmuxNextImportCards' `ImportSuggestionsCenter` sets ``cards``) and a card's button
/// back to it. App-wide like ``AgentPaneNowPlaying``: each page gets the cards at load and
/// handshake and again on every change. Not an AgentPaneView extension: that type is at its size limit.
@MainActor
public final class AgentPaneImportCards {
    public static let shared = AgentPaneImportCards()

    /// One deck; the App uses `shared`, a test its own.
    init() {}

    /// The New Tab list as the page draws it (`{title, cards: [...]}`, every text already
    /// localized); null when there is nothing to show or the cards are off.
    public var cards: JSONValue = .null {
        didSet {
            guard cards != oldValue else { return }
            for view in views.allObjects { send(to: view) }
        }
    }
    /// Runs a card's button (`importCards.act {id, action}`).
    public var onAction: ((_ id: String, _ action: String) -> Void)?
    private let views = NSHashTable<AgentPaneView>.weakObjects()

    /// A page's button: a card id and one of the card actions, a short lowercase ASCII word.
    public nonisolated struct Act: Hashable, Sendable {
        public var id: String
        public var action: String

        init?(_ params: [String: Any]?) {
            guard let id = params?["id"] as? String, let action = params?["action"] as? String,
                  (1...200).contains(id.count), (1...16).contains(action.count),
                  action.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { return nil }
            self.id = id
            self.action = action
        }
    }

    /// The cards, read now, as a page host event; `view` then also gets every change.
    func event(for view: AgentPaneView) -> AgentPageEvent {
        views.add(view)
        return .importCards(cards)
    }

    /// Pushes the cards, read now, to `view`'s page; `view` then also gets every change.
    func push(to view: AgentPaneView) {
        views.add(view)
        send(to: view)
    }

    private func send(to view: AgentPaneView) {
        let event = AgentPageEvent.importCards(cards)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyImportCards?.(\(event.value.compactText));"])
    }

    /// Runs a page's button; false when the App has not wired the cards.
    func perform(_ act: Act) -> Bool {
        guard let onAction else { return false }
        onAction(act.id, act.action)
        return true
    }
}

extension AgentPageEvent {
    /// The New Tab page's import cards (`importCards`); null while there are none.
    static func importCards(_ cards: JSONValue) -> AgentPageEvent {
        AgentPageEvent(kind: "importCards", value: cards)
    }
}
