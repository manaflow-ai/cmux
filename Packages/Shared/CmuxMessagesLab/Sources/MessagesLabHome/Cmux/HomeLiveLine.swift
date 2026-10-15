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
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func show(_ activity: HomeLiveActivity?) {
        guard activity != self.activity else { return }
        self.activity = activity
        clock?.invalidate()
        clock = nil
        if activity != nil {
            // A display clock for the elapsed seconds, not a synchronisation delay.
            let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            self.clock = clock
        }
        tick()
    }

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

    static func text(_ activity: HomeLiveActivity, now: Date) -> String {
        let seconds = now.timeIntervalSince(activity.since).rounded(.down)
        guard seconds.isFinite, seconds >= 1 else { return activity.line }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        guard let elapsed = formatter.string(from: seconds) else { return activity.line }
        return "\(activity.line) · \(elapsed)"
    }
}

extension MessagesLabHomeView {
    /// Automation (DEBUG socket): the host status line under the transcript (ask 9, `.setNotice`).
    public var debugStatusLine: String? { controller.store?.state.ui.notice }
}
