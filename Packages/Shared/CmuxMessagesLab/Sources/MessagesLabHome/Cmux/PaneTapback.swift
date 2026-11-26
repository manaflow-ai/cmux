import AppKit

// cmux: MessagesLab 7518134 Host.swift's `chooseTapback` (not vendored), for the pane controller.
// Messages times the badge's pop, the rows' move above it and the highlight's fade from the
// input that chose the tapback in the message menu; AppKit sends the menu action only when its
// menu has closed, 0.40-0.45 s after the press and at a different time in every take. In
// MessagesLab the action dispatches `.react` at once; in Home it goes to HomeStore
// (`ChatIntents.react`) and the commit arrives with the owner's answer, so the input is kept here
// and HomeProjection sets `MessagesWindowView.tapbackInput` around that commit (`takeTapbackChoice`).

/// The menu input that chose my next tapback: the message and kind it chose, at a media time.
struct TapbackChoice {
    var message: ID
    var kind: Reaction.Kind
    var input: CFTimeInterval
}

extension ChatController {
    /// A tapback chosen in the message menu. The input is AppKit's current event at the action (a
    /// click's press, a key, a right-button release that ends a press-drag), only when it came after
    /// the menu opened (the release that opened it is not the choice) and less than 1 s ago; else
    /// the tapback is timed from its commit, as before. No event is made or sent: only read.
    func chooseTapback(_ ref: PartRef, _ kind: Reaction.Kind) {
        let now = CACurrentMediaTime(), opened = menuHighlight?.openedAt ?? now
        let input = NSApp.currentEvent.flatMap { e -> CFTimeInterval? in
            switch e.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseUp, .keyDown:
                return e.timestamp > opened && e.timestamp <= now && now - e.timestamp < 1 ? e.timestamp : nil
            default: return nil
            }
        }
        tapbackChoice = input.map { TapbackChoice(message: ref.messageId, kind: kind, input: $0) }
        intents?.react(ref, kind)
        menuHighlight?.fadeForChoice(origin: input.map { $0 + MessagesWindowView.menuTapbackStart })
    }

    /// How late after the input a commit may still take the input's timing. MessagesLab's action
    /// comes 0.40-0.45 s after the press (its begin time then lies at most ~60 ms back); Home's
    /// commit waits for HomeStore's owner as well. A later commit is timed from itself: a begin
    /// time further back would start the badge's pop and the rows' move part-way through.
    static let latestTapbackCommit = MessagesWindowView.menuTapbackStart + 0.1

    /// The kept choice when `action` is its commit (my tapback of that kind on that message, at most
    /// `latestTapbackCommit` after the input); taken once. Any other own tapback ends it.
    func takeTapbackChoice(for action: Action) -> TapbackChoice? {
        guard case let .react(ref, kind, nil) = action, let choice = tapbackChoice else { return nil }
        tapbackChoice = nil
        guard choice.message == ref.messageId, choice.kind == kind,
              CACurrentMediaTime() - choice.input <= Self.latestTapbackCommit else { return nil }
        return choice
    }

    /// Dispatches a HomeStore change; my tapback chosen in the menu is timed from its input
    /// (MessagesWindowView.tapbackInput, engine time), as MessagesLab's chooseTapback does.
    func dispatchTimingTapback(_ action: Action) {
        guard let choice = takeTapbackChoice(for: action), let demo else { return dispatch(action) }
        demo.tapbackInput = choice.input - start
        dispatch(action)
        demo.tapbackInput = nil
    }
}
