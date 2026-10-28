import CmuxHomeCore
import Foundation

/// The Chief's "working on" line (`run.activity`, HomeStore.live) in
/// MessagesLab's host status-line slot (ask 9, `.setNotice`): the line and
/// the time since that work began, which the app counts itself (the owner
/// sends no per-second frames). The clock runs only while a line shows.
@MainActor
final class HomeLiveLine {
    /// Sends the line (nil: none) to the transcript's store.
    var dispatch: (String?) -> Void = { _ in }
    private var activity: HomeLiveActivity?
    /// The run's newest thought (``HomeLiveRun/thought``): the narration row's source.
    private var thought: String?
    private var shown: String?
    /// How the line reads (Debug Settings > Home > Running indicator), read at each tick so a
    /// change shows on the next second.
    var style: () -> HomeTurnProgressStyle = { .narrated }
    private var clock: Timer?
    private var hiding = false
    /// Counts hide requests: a close pending for an earlier one never closes a later one early.
    private var hides = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func show(_ activity: HomeLiveActivity?, thought: String? = nil) {
        if activity != nil { hiding = false }
        if let activity { steps.record(activity) }
        if thought != self.thought {
            self.thought = thought
            // A new thought on the same step: the narration row changes now, not on the next second.
            if activity != nil, activity == self.activity, clock != nil { tick() }
        }
        // The same line again after a hide stopped its clock: the clock runs again.
        guard activity != self.activity || (activity != nil && clock == nil) else { return }
        self.activity = activity
        clock?.invalidate()
        clock = nil
        if activity != nil {
            // A display clock for the elapsed seconds, not a synchronisation delay.
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                guard self != nil else { return timer.invalidate() } // the line's view went away
                Task { @MainActor [weak self] in self?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
        tick()
    }

    /// The line closes on the display frame after the one that presents the commit that lands the reply
    /// (cx-06vn1: the first display link fire after that commit starts the frame that presents it, so a
    /// change there joins the hand-off frame); a line shown again before then stays.
    func hide(after controller: ChatController) {
        guard activity != nil, !hiding else { return }
        hiding = true
        hides += 1
        let ticket = hides
        closeAfterHandOffFires = nil
        // A pending close shows the line as it is: no new second while it waits.
        clock?.invalidate()
        clock = nil
        // Not on screen (occluded, minimized, no window): no display frame comes and nothing moves on screen.
        guard controller.host.window?.occlusionState.contains(.visible) == true else { return close(ticket, controller) }
        controller.nextFrame { [weak self, weak controller] in
            guard let self, self.hiding, self.hides == ticket else { return }
            guard let controller else { return self.close(ticket, nil) }
            controller.nextFrame { [weak self, weak controller] in self?.close(ticket, controller) }
        }
    }

    private func close(_ ticket: Int, _ controller: ChatController?) {
        guard hiding, hides == ticket else { return }
        hiding = false
        show(nil)
        // The turn is over: its steps go with its line (and an open details popover).
        steps = HomeTurnSteps()
        onClose?()
        closed(fires: controller?.frameTick.fires)
    }

    /// Automation (DEBUG socket): the display frame the reply's hand-off (`.streamEnd(_, replacedBy:)`) was
    /// dispatched in, and the display frames from it to the line's close (nil: no line closed after a hand-off).
    var handOffFire: Int?
    private(set) var closeAfterHandOffFires: Int?

    private func closed(fires: Int?) {
        closeAfterHandOffFires = if let fires, let handOffFire { fires - handOffFire } else { nil }
        handOffFire = nil
    }

    /// The transcript's store was made again (install): it shows the line again.
    func resend() {
        shown = nil
        tick()
    }

    func stop() {
        // A close pending when the view stops never runs.
        hiding = false
        hides += 1
        clock?.invalidate()
        clock = nil
    }

    private func tick() {
        onTick?()
        let at = now()
        let text = activity.map { HomeTurnProgress(steps: steps.steps, current: $0, thought: thought, now: at, style: style()).text }
        guard text != shown else { return }
        shown = text
        dispatch(text)
    }

    /// The running turn's steps so far (one per distinct "working on" line), for the details popover.
    private(set) var steps = HomeTurnSteps()
    /// Each display-clock second (and each new line): an open details popover counts on.
    var onTick: (() -> Void)?
    /// The turn's line closed: an open details popover closes with it.
    var onClose: (() -> Void)?

    /// The current details (steps, durations, total), as of now.
    func details() -> HomeTurnDetails? {
        activity == nil ? nil : steps.details(now: now())
    }

    private static let minutes = formatter([.minute, .second])
    private static let hours = formatter([.hour, .minute])

    private static func formatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = units
        formatter.maximumUnitCount = 2
        return formatter
    }

    static func text(_ activity: HomeLiveActivity, now: Date) -> String {
        guard let elapsed = elapsed(now.timeIntervalSince(activity.since)) else { return activity.line }
        return "\(activity.line) · \(elapsed)"
    }

    /// "4s", "1m 5s", "2h 3m"; nil under a second.
    static func elapsed(_ interval: TimeInterval) -> String? {
        let seconds = interval.rounded(.down)
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let formatter = seconds >= 3600 ? hours : minutes
        return formatter.string(from: seconds)
    }
}

extension MessagesLabHomeView {
    /// Automation (DEBUG socket): the host status line under the transcript (ask 9, `.setNotice`).
    public var debugStatusLine: String? { controller.store?.state.ui.notice }
    /// Automation (DEBUG socket): whole-window rebuilds of the projection (no animation, a scroll restore).
    public var debugRebuilds: Int { projection.rebuilds }
    /// Automation (DEBUG socket): the streaming bubbles' texts (ask 11), oldest first.
    public var debugStreamTexts: [String] { controller.store?.state.ui.streams.filter { !$0.parts.isEmpty }.map(\.text) ?? [] }
    /// Automation (DEBUG socket): display frames from the reply's hand-off to the activity line's close.
    public var debugLineCloseAfterHandOffFires: Int? { projection.liveLine.closeAfterHandOffFires }
}

extension HomeProjection {
    /// Dispatches the running reply's stream actions; the hand-off (`.streamEnd(_, replacedBy: message)`)
    /// notes its display frame for automation (cx-06vn1).
    func dispatchStreamed(_ actions: [Action]) {
        for action in actions {
            if case .streamEnd(_, _?) = action { liveLine.handOffFire = controller.frameTick.fires }
            controller.dispatch(action)
        }
    }
}
