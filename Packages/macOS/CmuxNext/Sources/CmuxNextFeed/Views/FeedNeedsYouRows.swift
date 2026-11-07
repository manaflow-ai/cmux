public import Foundation

/// One request of the pinned Needs you section as values, for a web page to draw (the Home Messages
/// page's Needs you, webviews/src/pages/home-messages/cards/needsYou): the words ``FeedNeedsYouView``
/// draws (``FeedRowContent``) and the one-click answers its row offers (``FeedAnswerControls``).
public nonisolated struct FeedNeedsYouRow: Sendable, Equatable, Encodable {
    public struct Answer: Sendable, Equatable, Encodable {
        /// `decline` or `primary` (``FeedNeedsYouPin/answer(_:with:)``).
        public var id: String
        public var title: String
        /// `plain`, `primary` or `destructive`.
        public var role: String
        /// False while the Feed sends an earlier answer or is not connected.
        public var enabled: Bool
    }

    public var id: String
    public var headline: String
    /// Who asked and where (the row's meta line), else who posted it.
    public var who: String
    public var urgent: Bool
    public var answers: [Answer]
}

/// What the section shows: its title, the listed requests, the "N more" count's words and the look.
/// Encoded as the page's `needsYou` event (no `more` when all are listed).
public nonisolated struct FeedNeedsYouRows: Sendable, Equatable, Encodable {
    public var title: String
    public var rows: [FeedNeedsYouRow]
    public var more: String?
    /// ``FeedNeedsYouStyle`` raw value (Debug Settings > Feed > Needs you in Home).
    public var look: String
}

extension FeedNeedsYouPin {
    /// The section as values, `limit` requests listed (``FeedNeedsYouView``'s split); nil when
    /// nothing waits.
    public func rows(limit: Int = 3) -> FeedNeedsYouRows? {
        let requests = model.needsYou
        guard !requests.isEmpty else { return nil }
        let (shown, more) = FeedNeedsYouView.split(requests, limit: max(1, limit))
        let place = model.place
        let rows = shown.map { item in
            let content = FeedRowContent(item: item, place: place?(item))
            return FeedNeedsYouRow(id: item.id, headline: content.headline, who: content.meta.isEmpty ? item.poster.displayLabel : content.meta,
                                   urgent: content.isUrgent, answers: answers(item))
        }
        return FeedNeedsYouRows(title: FeedStrings.needsYou, rows: rows, more: more > 0 ? FeedStrings.needsYouMore(more) : nil,
                                look: FeedTunables.needsYouStyle.value.rawValue)
    }

    /// The one-click answers of `item`'s row: Decline, then the primary (``FeedAnswerControls``'s
    /// buttons). A request answered by picking or typing (a question, a choice) or with its own
    /// controls (an approval, a review) has none: its row opens it.
    func answers(_ item: FeedItem) -> [FeedNeedsYouRow.Answer] {
        let primary: (title: String, destructive: Bool, decline: String?)
        switch item.prompt {
        case let .confirm(prompt): primary = (prompt.confirmLabel ?? FeedStrings.confirm, prompt.destructive, prompt.cancelLabel)
        case .signIn: primary = (FeedStrings.signIn, false, nil)
        case .passkey: primary = (FeedStrings.usePasskey, false, nil)
        case .handoff: primary = (FeedStrings.takeOver, false, nil)
        case .file: primary = (FeedStrings.chooseFile, false, nil)
        case .input, .custom: primary = (FeedStrings.open, false, nil)
        case .notice, .approve, .choice, .question, .review: return []
        }
        let enabled = !model.isPending(item.id) && model.connection == .connected
        return [FeedNeedsYouRow.Answer(id: "decline", title: primary.decline ?? FeedStrings.decline, role: "plain", enabled: enabled),
                FeedNeedsYouRow.Answer(id: "primary", title: primary.title, role: primary.destructive ? "destructive" : "primary", enabled: enabled)]
    }

    /// Answers request `id` as its row's button `answer` (`decline` or `primary`) does.
    public func answer(_ id: String, with answer: String) {
        guard let item = model.item(id), !answers(item).isEmpty else { return }
        if answer == "decline" {
            if case .confirm = item.prompt { _ = model.answer(item.id, .confirm(false)) } else { model.decline(item.id) }
            return
        }
        guard answer == "primary" else { return }
        switch item.prompt {
        case .confirm: _ = model.answer(item.id, .confirm(true))
        case .handoff:
            _ = model.answer(item.id, .handoff(.takenOver, note: nil))
            model.open(item.id)
        default: model.open(item.id)
        }
    }

    /// A click on request `id`: its source opens (``open(_:)``).
    public func open(id: String) {
        if let item = model.item(id) { open(item) }
    }
}
