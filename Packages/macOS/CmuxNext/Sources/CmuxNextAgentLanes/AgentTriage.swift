public import CmuxNextActions
public import CmuxNextAgentActivity
public import CmuxNextAgentPane
import Foundation

/// Triage (wow idea 22): clear every agent waiting on the person from the keyboard, from anywhere.
/// Go to Longest-Waiting Agent (`agent.triage.next`, Ctrl-Cmd-;) opens the chat that has waited
/// longest at a permission, a question or a plan approval; on one of those chats it opens the
/// next. Allow and Go to Next Waiting Agent (`agent.triage.answer`, Ctrl-Cmd-Y) answers the chat
/// on screen the way its own card does (allow once, or a question's first choice: the page's
/// `triageAnswer`) and opens the next, so five waiting agents take five presses.
///
/// The queue is Go to Next Agent Needing Input's (``AgentPriorityChats/needingInput(now:)``, every
/// machine's waiting index, archived and snoozed chats left out), ordered by how long each has
/// waited instead of pinned-then-newest. Nothing is kept between presses: the chat on screen says
/// where the queue goes on from. Answer only ever answers the chat on screen, whose card shows the
/// exact command or question; a press anywhere else opens the longest-waiting chat first.
@MainActor
public final class AgentTriage {
    public static let next: ActionID = "agent.triage.next"
    public static let answer: ActionID = "agent.triage.answer"

    /// The agent chat on screen: its acpmux session, and how to answer its ask on the page
    /// (`byPerson`: the person's own key, the gesture the answer carries).
    public struct Shown {
        public let session: String
        public let answer: @MainActor (_ byPerson: Bool) -> Void

        public init(session: String, answer: @escaping @MainActor (_ byPerson: Bool) -> Void) {
            self.session = session
            self.answer = answer
        }
    }

    private let chats: AgentPriorityChats

    public init(chats: AgentPriorityChats) {
        self.chats = chats
    }

    /// `waiting` longest-waiting first: by `since` (when the lane entered `input`), a lane with no
    /// time after the rest, then by id so the order is stable.
    public static func queue(_ waiting: [AgentActivityLane]) -> [AgentActivityLane] {
        waiting.sorted { a, b in
            let sinceA = a.since ?? .distantFuture, sinceB = b.since ?? .distantFuture
            if sinceA != sinceB { return sinceA < sinceB }
            return a.id < b.id
        }
    }

    /// The chat a press opens: the first of `queue`, or, when `shown` is one of its chats, the one
    /// after it (wrapping). Nil when no other chat waits.
    public static func target(in queue: [AgentActivityLane], after shown: String?) -> AgentActivityLane? {
        guard let shown, let index = queue.firstIndex(where: { $0.id == shown }) else { return queue.first }
        guard queue.count > 1 else { return nil }
        return queue[(index + 1) % queue.count]
    }

    /// Binds both actions into `registry` (it holds this triage). `shown` reads the chat on screen
    /// for an invocation; `open` shows a chat, as Go to Next Agent Needing Input does.
    public func bind(into registry: ActionRegistry, shown: @escaping @MainActor (ActionInvocation) -> Shown?,
                     open: @escaping @MainActor (AgentActivityLane) -> Void) {
        registry.bindEffect(Self.next, effect: { [self] invocation in
            guard ActionRunScope.viewChangeAllowed() else { return .done }
            let queue = Self.queue(chats.needingInput())
            guard let lane = Self.target(in: queue, after: shown(invocation)?.session) else {
                return .refused(queue.isEmpty ? Self.noneWaiting : Self.noOtherWaiting, quiet: true)
            }
            open(lane)
            return .done
        })
        registry.bindEffect(Self.answer, effect: { [self] invocation in
            guard ActionRunScope.viewChangeAllowed() else { return .done }
            let queue = Self.queue(chats.needingInput())
            let onScreen = shown(invocation)
            // Only a waiting chat the person is looking at is answered; its card shows the ask.
            if let onScreen, queue.contains(where: { $0.id == onScreen.session }) {
                onScreen.answer(invocation.origin == .user)
            }
            guard let lane = Self.target(in: queue, after: onScreen?.session) else {
                return queue.isEmpty ? .refused(Self.noneWaiting, quiet: true) : .done
            }
            open(lane)
            return .done
        })
    }

    /// Binds both actions with `chat`, the agent chat a run sees on screen (its pane's selected
    /// tab): its page answers its own ask on `triageAnswer`, carrying the person's gesture.
    public func bind(into registry: ActionRegistry, chat: @escaping @MainActor (ActionInvocation) -> AgentPaneView?,
                     open: @escaping @MainActor (AgentActivityLane) -> Void) {
        bind(into: registry, shown: { invocation in
            guard let view = chat(invocation), let session = view.model.sessionId else { return nil }
            return Shown(session: session) { view.runPermissionAction("triageAnswer", byPerson: $0) }
        }, open: open)
    }

    static var noneWaiting: String {
        String(localized: "agent.needsInput.none", defaultValue: "No agent is waiting for input", bundle: .module)
    }

    static var noOtherWaiting: String {
        String(localized: "agent.triage.noOther", defaultValue: "No other agent is waiting for input", bundle: .module)
    }
}
