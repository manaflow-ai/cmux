public import AppKit
import CmuxNextCompat
import CmuxNextDaemonService
import CmuxNextDesign
public import CmuxNextWakeups

/// The window's Activity indicator in the top row, after the host pressure indicator
/// (`WindowRootView.activityIndicator`; plans/cmux-next/long-jobs-DESIGN.md). Hidden while no long job
/// runs; while one does, a still glyph (no spin: the jobs' own progress is the motion), whose click
/// opens ``ActivityPopover`` with every job. Two designs behind `ui.activityIndicator`: `labeled` (the
/// default, Lawrence 2026-11-03: the glyph with the first job's title and percent beside it) and `icon`
/// (the glyph alone, the first job and its percent in the tooltip).
///
/// It observes ``LongJobs/all`` and the setting while in a window, and stops when it leaves it.
public final class ActivityIndicatorView: NSView {
    static let identifier = "cmux.titlebar.activity"
    static let symbol = "hourglass"
    /// The `labeled` design's widest text, so a long title never pushes the strips.
    static let maxLabeledWidth: CGFloat = 260
    let button = TitlebarBandButton(symbol: ActivityIndicatorView.symbol)
    private let jobs: LongJobs
    private let labeled: @MainActor () -> Bool
    private let onVisibilityChange: () -> Void
    private var observation: Task<Void, Never>?
    private lazy var popover = ActivityPopover()
    private var madePopover = false
    private(set) var shown: [LongJob] = []
    private(set) var isLabeled = false

    /// `labeled` reads `ui.activityIndicator` (true for `labeled`; the app passes its settings snapshot).
    public init(jobs: LongJobs, labeled: @escaping @MainActor () -> Bool, onVisibilityChange: @escaping () -> Void) {
        self.jobs = jobs
        self.labeled = labeled
        self.onVisibilityChange = onVisibilityChange
        super.init(frame: .zero)
        isHidden = true
        button.target = self
        button.action = #selector(togglePopover)
        button.setAccessibilityIdentifier(Self.identifier)
        addSubview(button)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The glyph's square, or the `labeled` design's glyph and text.
    public var width: CGFloat {
        isLabeled ? min(Self.maxLabeledWidth, button.preferredWidth) : TitlebarBandButton.side
    }

    public override func layout() {
        super.layout()
        button.frame = bounds
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observation?.cancel()
        observation = nil
        guard window != nil else {
            if madePopover { popover.closePanel() }
            return
        }
        let (jobs, labeled) = (jobs, labeled)
        // task-owner: cancelled when the view leaves its window (a released view ends it at the next change); event-driven (Observation of LongJobs and the setting)
        observation = Task { [weak self] in
            for await (list, wide) in ObservationStream({ (jobs.all, labeled()) }) {
                guard !Task.isCancelled, let self else { return }
                show(list, labeled: wide)
            }
        }
    }

    func show(_ list: [LongJob], labeled wide: Bool) {
        let (wasHidden, oldWidth) = (isHidden, width)
        shown = list
        isLabeled = wide
        isHidden = list.isEmpty
        let summary = list.first.map(Self.summary) ?? ""
        button.text = wide && !list.isEmpty ? summary : nil
        let label = list.isEmpty ? DaemonRecoveryStrings.activityTitle : "\(DaemonRecoveryStrings.activityTitle): \(summary)"
        button.setAccessibilityLabel(label)
        button.themedToolTip = label
        if list.isEmpty {
            if madePopover { popover.close() }
        } else if madePopover, popover.isShown {
            popover.update(list)
        }
        if wasHidden != isHidden || oldWidth != width {
            superview?.needsLayout = true
            onVisibilityChange()
        }
    }

    /// "Cleaning up stored terminal output 43%": a job's title and, when known, its percent.
    static func summary(_ job: LongJob) -> String {
        [job.displayTitle, job.percentText].compactMap(\.self).joined(separator: " ")
    }

    @objc private func togglePopover() {
        if madePopover, popover.isShown { popover.close() } else { openPopover() }
    }

    func openPopover() {
        guard !shown.isEmpty else { return }
        madePopover = true
        popover.content.update(shown)
        popover.show(relativeTo: button)
    }

    var isPopoverShown: Bool { madePopover && popover.isShown }
}
