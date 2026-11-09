import AppKit

/// The quiet line above the compose field while Chief runs a turn:
/// "Working · 12s" (T3 Code's "Working for 12s" beside Stop,
/// cmux-design-references `apps/t3-code/live/task-running-thinking.png`,
/// `topics/status-and-progress.md`). While an approval waits the owner hides
/// it: the transcript's last row says "Waiting for you" in the attention color
/// (MessagesLabHome `HomeStatusLine`).
///
/// The owner calls ``show(since:)`` whenever the service's working set or the
/// pending approval changes. One repeating one-second timer exists only while
/// the line shows; it only redraws the elapsed time.
@MainActor
final class ChiefWorkingStatusView: NSTextField {
    private var since: ContinuousClock.Instant?
    private var timer: Timer?
    private var theme = ChiefTheme.current()

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        font = .systemFont(ofSize: 10)
        isHidden = true
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Whether the line shows (a turn runs).
    var isShown: Bool { since != nil }

    /// Shows the line for a turn started at `since` (nil hides it).
    func show(since: ContinuousClock.Instant?) {
        self.since = since
        isHidden = since == nil
        let ticks = since != nil
        if ticks, timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() } // main-proof: scheduled on the main run loop
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !ticks {
            stop()
        }
        render()
    }

    /// Ends the timer (the turn ended or the view went away).
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func apply(_ theme: ChiefTheme) {
        self.theme = theme
        render()
    }

    private func render() {
        guard let since else {
            stringValue = ""
            setAccessibilityLabel(nil)
            return
        }
        let seconds = max(0, Int((ContinuousClock.now - since).components.seconds))
        let text = ChiefStrings.workingElapsed(.seconds(seconds))
        textColor = theme.textSecondary
        if stringValue != text {
            stringValue = text
            setAccessibilityLabel(text)
        }
    }
}

extension ChiefStrings {
    /// "Working · 12s" while a turn runs; the duration is the system's
    /// narrow unit style for the locale.
    static func workingElapsed(_ elapsed: Duration) -> String {
        let time = elapsed.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow))
        return String(format: String(localized: "chief.working.elapsed", defaultValue: "Working · %@"), time)
    }
}
