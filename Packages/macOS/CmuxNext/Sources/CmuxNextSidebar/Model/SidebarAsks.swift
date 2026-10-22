import CmuxNextCompat
import Foundation
public import Observation

/// Questions that wait on the person in the sidebar's notice card (an agent's
/// request for a Cloud machine), instead of a sheet over their work. `ask`
/// shows its card in every window's sidebar, oldest first and one at a time,
/// and returns true only for the card's prominent button; another button, the
/// x, a cancelled caller or an asker that went away answer false. Only the card's own views send the
/// answers (`SidebarIntent.noticeAction` / `dismissNotice`); no socket does.
@MainActor @Observable
public final class SidebarAsks {
    private struct Ask {
        var card: SidebarNoticeCard
        var answer: CheckedContinuation<Bool, Never>
        /// Opens who asked (the card's requester line); nil when nothing opens.
        var reveal: (@MainActor () -> Void)?
    }

    /// The action of the card's requester line: it opens who asked and answers nothing.
    public static let revealAction = "ask.reveal"

    private var asks: [Ask] = []

    public init() {}

    /// The oldest open question's card, nil for none.
    public var card: SidebarNoticeCard? { asks.first?.card }

    /// Shows `card` (a unique id; its prominent action is the yes) until the person answers.
    /// `asker` (an agent chat) is watched with `present` (observed): once the asker is gone, the
    /// card goes and the answer is false. An asker not present when asked (shown nowhere here) never expires it.
    /// `reveal` opens who asked: with it, the card's ``SidebarNoticeCard/requester`` line is a button
    /// (``revealAction``) that runs it and leaves the question open.
    public func ask(_ card: SidebarNoticeCard, asker: String? = nil, present: @escaping @MainActor @Sendable (String) -> Bool = { _ in true },
                    reveal: (@MainActor () -> Void)? = nil) async -> Bool {
        var card = card
        card.awaitsAnswer = true
        if reveal != nil { card.requester?.action = Self.revealAction }
        let id = card.id
        let watch = asker.flatMap { asker -> Task<Void, Never>? in
            guard present(asker) else { return nil }
            // task-owner: one watch of the asker per open question; cancelled when it is answered
            return Task { @MainActor [weak self] in
                for await here in ObservationStream({ present(asker) }) where !here { self?.answer(id, action: nil); return }
            }
        }
        defer { watch?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { answer in
                if Task.isCancelled { answer.resume(returning: false) } else { asks.append(Ask(card: card, answer: answer, reveal: reveal)) }
            }
        } onCancel: {
            Task { @MainActor in self.answer(id, action: nil) }
        }
    }

    /// Asks with a card of `yes` (prominent) and `no` buttons; the x is `no` too. `requester` names
    /// who asked and where; `reveal` opens it (see ``ask(_:asker:present:reveal:)``).
    public func ask(_ title: String, detail: String, lines: [String] = [], symbol: String? = nil, yes: String, no: String,
                    requester: SidebarNoticeCard.Requester? = nil, asker: String? = nil,
                    present: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }, reveal: (@MainActor () -> Void)? = nil) async -> Bool {
        let actions = [SidebarNoticeCard.Action(id: "yes", title: yes, prominent: true), SidebarNoticeCard.Action(id: "no", title: no)]
        var card = SidebarNoticeCard(id: "ask.\(UUID().uuidString)", symbol: symbol, title: title, detail: detail, lines: lines,
                                     actions: actions, dismissLabel: no)
        card.requester = requester
        return await ask(card, asker: asker, present: present, reveal: reveal)
    }

    /// Answers the open question `id` with the button `action` (nil: the x); ``revealAction``
    /// opens who asked instead and leaves the question open.
    /// False when no open question has that id (the card belongs to another owner).
    @discardableResult
    public func answer(_ id: String, action: String?) -> Bool {
        guard let index = asks.firstIndex(where: { $0.card.id == id }) else { return false }
        if action == Self.revealAction {
            // The requester line opens who asked; the question stays open.
            asks[index].reveal?()
            return true
        }
        let ask = asks.remove(at: index)
        ask.answer.resume(returning: ask.card.actions.contains { $0.id == action && $0.prominent })
        return true
    }
}
