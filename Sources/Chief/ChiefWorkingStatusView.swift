import AppKit

/// The quiet line above the compose field while Chief runs a turn:
/// "Working · 12s", or "Waiting for you" in the attention color while an
/// approval waits (T3 Code's "Working for 12s" beside Stop,
/// cmux-design-references `apps/t3-code/live/task-running-thinking.png`,
/// `topics/status-and-progress.md`).
///
/// The owner calls ``show(since:waiting:)`` whenever the service's working set
/// or the pending approval changes. One repeating one-second timer exists only
/// while a turn runs and nothing waits; it only redraws the elapsed time.
@MainActor
final class ChiefWorkingStatusView: NSTextField {
    private var since: ContinuousClock.Instant?
    private var waiting = false
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

    /// Shows the line for a turn started at `since` (nil hides it); `waiting`
    /// swaps the elapsed time for "Waiting for you".
    func show(since: ContinuousClock.Instant?, waiting: Bool) {
        self.since = since
        self.waiting = since != nil && waiting
        isHidden = since == nil
        let ticks = since != nil && !self.waiting
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
        let text: String
        if waiting {
            text = ChiefStrings.workingWaiting
            textColor = WorkspaceAttentionColor(configuredHex: nil).nsColor
        } else {
            let seconds = max(0, Int((ContinuousClock.now - since).components.seconds))
            text = ChiefStrings.workingElapsed(.seconds(seconds))
            textColor = theme.textSecondary
        }
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

    /// The working line while Chief waits on an approval.
    static var workingWaiting: String {
        String(localized: "chief.working.waiting", defaultValue: "Waiting for you")
    }
}
