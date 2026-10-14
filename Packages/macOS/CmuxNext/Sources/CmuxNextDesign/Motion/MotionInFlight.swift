import AppKit

/// The AppKit animations Motion started whose completion has not run yet,
/// oldest first, so they can end at once when the display goes to sleep.
///
/// A sleeping display draws no frame, so a running `animator()` change stops
/// where it is: a sidebar row opening stays half faded, and a closing row's
/// completion (which removes it) never runs. ``finish()`` applies each
/// running change's final values in a zero-length group, oldest first so a
/// later retarget wins, then runs the completions in the same order. A
/// completion runs once: the one AppKit delivers later is dropped.
@MainActor
enum MotionInFlight {
    private final class Entry {
        let changes: () -> Void
        let completion: (@MainActor @Sendable () -> Void)?
        let deadline: TimeInterval

        init(changes: @escaping () -> Void, completion: (@MainActor @Sendable () -> Void)?, deadline: TimeInterval) {
            self.changes = changes
            self.completion = completion
            self.deadline = deadline
        }
    }

    private static var entries: [Entry] = []

    /// Seconds past its expected end before an entry stops being replayed.
    /// Tests shorten it to expire entries at once.
    static var expirySlack: TimeInterval = 2

    /// Records a change about to animate for `seconds`, and returns the
    /// completion to hand AppKit in place of `completion`.
    static func track(_ changes: @escaping () -> Void, seconds: TimeInterval,
                      completion: (@MainActor @Sendable () -> Void)?) -> @MainActor @Sendable () -> Void {
        // Starts the sleep watch with the first animation that could need it.
        _ = DisplaySleep.shared
        let now = ProcessInfo.processInfo.systemUptime
        // A change whose completion AppKit never delivered (a superseded group) is not
        // replayed once it should long have ended; a spring settles within its slack.
        entries.removeAll { $0.deadline < now }
        let entry = Entry(changes: changes, completion: completion, deadline: now + seconds + expirySlack)
        entries.append(entry)
        return {
            guard let index = entries.firstIndex(where: { $0 === entry }) else { return }
            entries.remove(at: index)
            entry.completion?()
        }
    }

    /// Ends every running change now: its final values, then its completion.
    static func finish() {
        let now = ProcessInfo.processInfo.systemUptime
        let running = entries.filter { $0.deadline >= now }
        entries = []
        guard !running.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            for entry in running { entry.changes() }
        }
        for entry in running { entry.completion?() }
    }
}
