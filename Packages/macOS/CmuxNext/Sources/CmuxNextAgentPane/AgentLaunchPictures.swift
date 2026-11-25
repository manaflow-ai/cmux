import CmuxNextWakeups

/// Keeps the agent chats' launch pictures (``AgentPaneLaunchImages``) saved while the app runs, not only at a clean
/// quit, so a crash, a kill or an update's relaunch still draws each chat's last page at the next launch. Leo
/// 2026-11-22: "where is the cached thing + delta + simply showing the rendered appearance".
///
/// A save runs when a chat's page has painted and gone quiet (``settle`` after its first paint). It is the quit's
/// save (the app's `AgentQuitFiles.saveImages`): the pictures of the chats on screen, encoded and written off the
/// main thread, the saved set replaced by the chats on screen (one not painted yet keeps its last picture, so the
/// disk holds at most one picture per pane on screen). Saves are throttled: at most one per ``cooldown``; requests
/// inside it run once at its end. There is no repeating timer: each save answers a paint, and ``stop()`` (the
/// quit, which saves for itself) drops a pending one.
@MainActor
public final class AgentLaunchPictures {
    /// How long a chat's first paint waits before its picture is taken: the page settles (fonts, the kept
    /// tail's scroll, a fade-in) before it is what the next launch should show.
    public static let settle: Duration = .seconds(2)
    /// The least time between two saves.
    public static let cooldown: Duration = .seconds(30)

    private let save: @MainActor () async -> Void
    /// The pending save.
    private let timer: DemandTimer
    /// Ends the cooldown after a save.
    private let cooldownTimer: DemandTimer
    /// A save ran less than ``cooldown`` ago.
    private var cooling = false
    /// A save was asked for during the cooldown: it runs at its end.
    private var pending = false
    private var stopped = false

    /// - Parameters:
    ///   - clock: Times ``settle`` and ``cooldown``; tests pass their own.
    ///   - save: Takes and writes the pictures (the app's `AgentQuitFiles.saveImages`).
    public init(clock: any Clock<Duration> = ContinuousClock(), save: @escaping @MainActor () async -> Void) {
        self.save = save
        timer = DemandTimer(owner: "agent-pane.launch-pictures.save", clock: clock)
        cooldownTimer = DemandTimer(owner: "agent-pane.launch-pictures.cooldown", clock: clock)
    }

    /// A chat page painted its first frame: its picture is saved once it settled.
    public func pagePainted() { request(after: Self.settle) }

    /// The quit saves for itself: no save starts after this.
    public func stop() {
        stopped = true
        timer.cancel()
        cooldownTimer.cancel()
    }

    /// The quit that stopped them did not happen (a relaunch whose install failed): saves answer paints again.
    public func resume() { stopped = false }

    /// Asks for one save `delay` from now, or at the cooldown's end when one is running; a save already pending
    /// keeps its time.
    public func request(after delay: Duration) {
        guard !stopped else { return }
        guard !cooling else {
            pending = true
            return
        }
        timer.scheduleIfIdle(after: delay) { @MainActor [weak self] in await self?.run() }
    }

    private func run() async {
        guard !stopped, !cooling else { return }
        cooling = true
        cooldownTimer.schedule(after: Self.cooldown) { @MainActor [weak self] in self?.cooled() }
        await save()
    }

    private func cooled() {
        cooling = false
        guard pending else { return }
        pending = false
        request(after: .zero)
    }
}
