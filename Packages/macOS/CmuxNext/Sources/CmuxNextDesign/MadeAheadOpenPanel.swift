public import AppKit
import CmuxNextWakeups
import CoreGraphics
import os

/// The app's file picker, made ahead of the click: Home's "+" and an agent composer's
/// + > Attach files or images (a page's `<input type="file">`) take this panel.
///
/// `NSOpenPanel()` costs 105 to 120 ms on the main thread, about 300 ms for the process's
/// first one (frameworks and the panel service load), before `beginSheetModal` adds its own
/// 270 ms. Bench on a capture mini (macOS 26.3.1, a bare app, 2026-10-21): a new panel per
/// click first shows its sheet 830 ms after the click in a fresh process and 160 ms after it
/// later; the panel made ahead shows it after 95 ms, then 45 to 65 ms. One panel is made while
/// the person is idle and reused. The warm-up still costs that main-thread time once, at a
/// pause or while cmux is in the background.
///
/// The warm-up never waits on the panel service on the main thread: `NSOpenPanel()` blocks until its view
/// service answers, about 40 s when it never does (no GUI session, aws-m4pro-3, 2026-10-23). So it first asks
/// off the main thread whether the service can answer (``MadeAheadOpenPanelWorld/serviceReady``) with a
/// deadline, and makes the panel only after a yes. No answer in time, or no panel back, stops the warm-up
/// for the launch; a click then makes its panel on demand (``panel()``).
@MainActor
public final class MadeAheadOpenPanel {
    public static let shared = MadeAheadOpenPanel()

    private var made: NSOpenPanel?
    private var madeDefaults: OpenPanelDefaults?
    /// Whether the panel was made ahead of a click.
    public var isMade: Bool { made != nil }
    /// The warm-up checks run so far, and whether another is pending.
    public private(set) var warmChecks = 0
    public var isWarming: Bool { timer.isScheduled || asking != nil }
    /// Whether the warm-up gave up for this launch (no panel service, or no panel came back).
    public private(set) var stoppedWarming = false

    private let world: MadeAheadOpenPanelWorld
    private let timer: DemandTimer
    /// The pending off-main question to the panel service.
    private var asking: Task<Void, Never>?

    public convenience init() {
        self.init(world: .live)
    }

    init(world: MadeAheadOpenPanelWorld) {
        self.world = world
        timer = DemandTimer(owner: "openPanel.madeAhead.warm", clock: world.clock)
    }

    /// The panel made ahead when it is free (no sheet or window shows it), else a new one (it
    /// shows on another window). Either comes as a new panel would: one file, no folders, every
    /// type, the system's prompt and no message; the caller sets what it needs.
    public func panel() -> NSOpenPanel {
        let free = made.flatMap { $0.isVisible || $0.sheetParent != nil ? nil : $0 }
        guard let panel = free else {
            let panel = NSOpenPanel()
            if made == nil { keep(panel) }
            return panel
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = []
        madeDefaults?.apply(to: panel)
        return panel
    }

    /// Makes the panel once the person has paused (no input for a second), so its cost never
    /// lands on a keystroke or the click itself. Bounded: after ten busy checks it waits for the
    /// click. A view that offers the picker calls this when it reaches a window.
    public func warmWhenIdle() {
        guard made == nil, !stoppedWarming, !isWarming else { return }
        check(after: world.firstCheck, triesLeft: 10)
    }

    /// Keeps `panel` for later clicks, unless its view service never answered (no prompt): then the next
    /// click makes a new one, and the launch goes on.
    @discardableResult
    private func keep(_ panel: NSOpenPanel) -> Bool {
        guard let defaults = OpenPanelDefaults(of: panel) else { return false }
        made = panel
        madeDefaults = defaults
        return true
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self else { return }
            warmChecks += 1
            guard made == nil else { return }
            switch world.gate() {
            case .never:
                return
            case .busy:
                if triesLeft > 1 { check(after: world.retry, triesLeft: triesLeft - 1) }
                return
            case .go:
                askService(triesLeft: triesLeft)
            }
        }
    }

    /// Asks the panel service off the main thread, then makes the panel only when it can answer.
    private func askService(triesLeft: Int) {
        let world = world
        asking = Task { [weak self] in
            let ready = await answer(within: world.serviceDeadline, clock: world.clock, world.serviceReady)
            self?.serviceAnswered(ready, triesLeft: triesLeft)
        }
    }

    private func serviceAnswered(_ ready: Bool, triesLeft: Int) {
        asking = nil
        guard made == nil, !stoppedWarming else { return }
        guard ready else {
            stoppedWarming = true // no answer in time: a click makes its panel on demand
            return
        }
        switch world.gate() {
        case .never:
            return
        case .busy:
            if triesLeft > 1 { check(after: world.retry, triesLeft: triesLeft - 1) }
        case .go:
            // No panel, or one whose view never loaded: give up for the launch.
            guard let panel = world.makePanel(), keep(panel) else {
                stoppedWarming = true
                return
            }
        }
    }
}

/// `ask`'s answer, or false when it has not come within `deadline`. Never waits past the deadline: a late
/// `ask` keeps only its own task, cancelled.
private func answer(within deadline: Duration, clock: any Clock<Duration>,
                    _ ask: @escaping @Sendable () async -> Bool) async -> Bool {
    // One-shot resume guard: the answer and the deadline race to resume one continuation (lock carve-out).
    let claimed = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { continuation in
        let resume: @Sendable (Bool) -> Void = { value in
            let first = claimed.withLock { done in
                defer { done = true }
                return !done
            }
            if first { continuation.resume(returning: value) }
        }
        // The deadline is the behavior (give up on a silent service): a DemandTimer, kept alive by the ask.
        let deadlineTimer = DemandTimer(owner: "openPanel.madeAhead.serviceDeadline", clock: clock)
        let asking = Task.detached {
            let value = await ask()
            resume(value)
            deadlineTimer.cancel()
        }
        deadlineTimer.schedule(after: deadline) {
            resume(false)
            asking.cancel()
        }
    }
}
