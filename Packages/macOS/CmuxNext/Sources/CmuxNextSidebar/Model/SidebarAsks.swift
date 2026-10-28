import CmuxNextCompat
public import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
        var answer: OnceContinuation<Bool, OnceContinuationError>
    }

    private var asks: [Ask] = []
    /// The app's one main-thread scheduler: the asker watches flush on it, and a cancelled caller's answer is posted on it.
    @ObservationIgnored private let mainWork: MainWorkScheduler

    /// - Parameter mainWork: The app's one main-thread scheduler (`AppServices.mainWork`).
    public init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
    }

    /// The oldest open question's card, nil for none.
    public var card: SidebarNoticeCard? { asks.first?.card }

    /// Shows `card` (a unique id; its prominent action is the yes) until the person answers.
    /// `asker` (an agent chat) is watched with `present` (observed): once the asker is gone, the
    /// card goes and the answer is false. An asker not present when asked (shown nowhere here) never expires it.
    public func ask(_ card: SidebarNoticeCard, asker: String? = nil, present: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }) async -> Bool {
        var card = card
        card.awaitsAnswer = true
        let id = card.id
        let mainWork = mainWork
        // One watch of the asker per open question, stopped when it is answered. Its apply answers the ask (a model
        // write), so it is a service observation and runs whether or not a sidebar shows the card. An agent's chat
        // closing is automation's change: its answer waits behind the person's input.
        let watch = asker.flatMap { asker -> ServiceObservation<Bool>? in
            guard present(asker) else { return nil }
            return ServiceObservation(.automation, owner: "SidebarAsks.asker", on: mainWork) { present(asker) } apply: { [weak self] here in
                if !here { self?.answer(id, action: nil) }
            }
        }
        defer { watch?.cancel() }
        return await withTaskCancellationHandler {
            // A card dropped without an answer is No, as the x is.
            (try? await withOnceContinuation { (answer: OnceContinuation<Bool, OnceContinuationError>) in
                if Task.isCancelled { answer.resume(returning: false) } else { asks.append(Ask(card: card, answer: answer)) }
            }) ?? false
        } onCancel: {
            // The cancelling thread is any thread: the card goes in one posted task in the caller's class.
            mainWork.postFromAnyThread(.automation, owner: "SidebarAsks.cancel") { _ = self.answer(id, action: nil) }
        }
    }

    /// Asks with a card of `yes` (prominent) and `no` buttons; the x is `no` too.
    public func ask(_ title: String, detail: String, lines: [String] = [], symbol: String? = nil, yes: String, no: String,
                    asker: String? = nil, present: @escaping @MainActor @Sendable (String) -> Bool = { _ in true }) async -> Bool {
        let actions = [SidebarNoticeCard.Action(id: "yes", title: yes, prominent: true), SidebarNoticeCard.Action(id: "no", title: no)]
        return await ask(SidebarNoticeCard(id: "ask.\(UUID().uuidString)", symbol: symbol, title: title, detail: detail, lines: lines,
                                           actions: actions, dismissLabel: no), asker: asker, present: present)
    }

    /// Answers the open question `id` with the button `action` (nil: the x).
    /// False when no open question has that id (the card belongs to another owner).
    @discardableResult
    public func answer(_ id: String, action: String?) -> Bool {
        guard let index = asks.firstIndex(where: { $0.card.id == id }) else { return false }
        let ask = asks.remove(at: index)
        ask.answer.resume(returning: ask.card.actions.contains { $0.id == action && $0.prominent })
        return true
    }
}
