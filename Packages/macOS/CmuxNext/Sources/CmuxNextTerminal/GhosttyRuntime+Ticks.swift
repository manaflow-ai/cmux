public import CmuxNextWakeups
import GhosttyNextKit

/// libghostty's app tick, after a coalesced wakeup (``ghosttyWakeup(_:)``), as the board task
/// `ghostty.tick` (``GhosttyTickClass``).
extension GhosttyRuntime {
    /// Wires the runtime to the app's main-thread scheduler: every app tick runs on its board, the
    /// runtime's own main-thread work posts on it, and Energy Saver follows its policy
    /// (``followEnergySaver(on:)``). The composition root calls it once, before the first terminal;
    /// until then a tick runs off the board.
    ///
    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler.
    ///   - holdsHiddenActions: A hidden terminal's state actions wait for it to show (feature
    ///     `terminalHiddenActionHold`); false: they apply at its window's frame, seen or not.
    public func attach(to mainWork: MainWorkScheduler, holdsHiddenActions: Bool = false) {
        ticks = GhosttyTickClass(work: mainWork)
        self.holdsHiddenActions = holdsHiddenActions
        followEnergySaver(on: mainWork)
    }

    /// The app's main-thread scheduler (``attach(to:holdsHiddenActions:)``); nil before that, and in tests.
    var mainWork: MainWorkScheduler? { ticks?.work }

    /// A terminal took a key (`TerminalSurfaceView.keyDown`): ticks run as input until its frame.
    public func noteTerminalKey() {
        ticks?.noteTerminalKey()
    }

    /// Runs one libghostty app tick on the main actor, as one board task once ``attach(to:holdsHiddenActions:)`` wired the board.
    ///
    /// - Parameter post: When the wakeup that queued it came (nil: run time only).
    func tick(posted post: MainTaskPost? = nil) {
        context.pending.store(false, ordering: .releasing)
        guard let ticks else { return appTick() }
        ticks.run(posted: post) { appTick() }
    }

    private func appTick() {
        guard let app else { return }
        // SAFETY: `app` is live (never freed); a tick runs on the main actor as Ghostty asks.
        unsafe ghostty_app_tick(app)
    }
}
