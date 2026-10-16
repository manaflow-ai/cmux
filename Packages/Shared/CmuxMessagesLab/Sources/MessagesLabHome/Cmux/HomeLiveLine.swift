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
    private var shown: String?
    private var clock: Timer?
    private var hiding = false
    /// Counts hide requests: a close scheduled for an earlier one does not close a later one early.
    private var hides = 0
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func show(_ activity: HomeLiveActivity?) {
        if activity != nil { hiding = false }
        guard activity != self.activity else { return }
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

    /// The line closes on the display frame after the one that presents the commit that lands the reply;
    /// a line shown again before then stays (a later hide starts its own count).
    func hide(after controller: ChatController) {
        guard activity != nil, !hiding else { return }
        hiding = true
        hides += 1
        let hide = hides
        let asked = controller.frameTick.fires
        // The first display link fire after the hand-off commit starts the frame that presents it: a change
        // there joins that same frame (cx-06vn1, the real turn's line closed with the hand-off). The line
        // keeps its row through that frame and closes on the next one.
        controller.nextFrame { [weak self, weak controller] in
            guard let self, self.hiding, self.hides == hide else { return }
            let close = { [weak self, weak controller] in
                guard let self, self.hiding, self.hides == hide else { return }
                self.hiding = false
                self.show(nil)
                self.closeFrames = controller.map { $0.frameTick.fires - asked }
            }
            if let controller { controller.nextFrame(close) } else { close() }
        }
    }

    /// Automation (DEBUG socket): the display frames from the refresh that asked the line to close (the one
    /// that landed the reply) to its close; nil until a line closed that way.
    private(set) var closeFrames: Int?

    /// The transcript's store was made again (install): it shows the line again.
    func resend() {
        shown = nil
        tick()
    }

    func stop() {
        clock?.invalidate()
        clock = nil
    }

    private func tick() {
        let text = activity.map { Self.text($0, now: now()) }
        guard text != shown else { return }
        shown = text
        dispatch(text)
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
        let seconds = now.timeIntervalSince(activity.since).rounded(.down)
        guard seconds.isFinite, seconds >= 1 else { return activity.line }
        let formatter = seconds >= 3600 ? hours : minutes
        guard let elapsed = formatter.string(from: seconds) else { return activity.line }
        return "\(activity.line) · \(elapsed)"
    }
}

extension MessagesLabHomeView {
    /// Automation (DEBUG socket): the host status line under the transcript (ask 9, `.setNotice`).
    public var debugStatusLine: String? { controller.store?.state.ui.notice }
    /// Automation (DEBUG socket): whole-window rebuilds of the projection (no animation, a scroll restore).
    public var debugRebuilds: Int { projection.rebuilds }
    /// Automation (DEBUG socket): the streaming bubbles' texts (ask 11), oldest first.
    public var debugStreamTexts: [String] { controller.store?.state.ui.streams.filter { !$0.parts.isEmpty }.map(\.text) ?? [] }
    /// Automation (DEBUG socket): display frames between the reply's hand-off refresh and the activity line's close.
    public var debugLineCloseFrames: Int? { projection.liveLine.closeFrames }
}
