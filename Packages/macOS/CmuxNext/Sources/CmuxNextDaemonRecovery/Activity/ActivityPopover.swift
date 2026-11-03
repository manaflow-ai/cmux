import AppKit
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextWakeups

/// The Activity popover under the top-row indicator: every running long job, its title, how far it is
/// (a bar when its size is known, the percent and its detail), and for a job that quitting would
/// interrupt, that it restarts. A popup of the shared native host, like the host pressure popover.
@MainActor
final class ActivityPopover {
    let content = ActivityPopoverView()
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.activity.popover"))
    private let card: OverlaySurfaceView

    init() {
        card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
    }

    var isShown: Bool { popup.isShown }
    /// The indicator it opened under, for a resize when its rows change.
    private weak var anchor: NSView?

    func show(relativeTo anchor: NSView) {
        guard anchor.window != nil else { return }
        self.anchor = anchor
        popup.panel.adoptThemeScope(of: anchor)
        card.applyTheme()
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        guard place(makeKey: true) else { return }
        popup.panel.makeFirstResponder(nil)
    }

    /// Updates the rows and, while shown, sizes the card to them (a job that came or went, a detail that wraps).
    func update(_ jobs: [LongJob]) {
        content.update(jobs)
        if isShown { place(makeKey: false) }
    }

    /// Shows or moves the card at the size of its rows under the anchor.
    @discardableResult
    private func place(makeKey: Bool) -> Bool {
        guard let anchor, let window = anchor.window else { return false }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: ActivityPopoverView.width, height: ceil(content.fittingSize.height))
        return popup.show(size: size, anchor: rect, in: window, preferred: .below, centered: true, makeKey: makeKey) != nil
    }

    func close() { popup.hide() }

    func closePanel() { popup.closePanel() }
}

/// The popover's rows: one ``ActivityJobRow`` per job, kept by job id, so a progress step or a heartbeat
/// changes only that row's text and bar (VoiceOver keeps its place); a job that came or went adds or
/// removes its row.
final class ActivityPopoverView: NSView {
    static let width: CGFloat = 320
    private let stack = NSStackView()
    private var rowsByID: [String: ActivityJobRow] = [:]
    private(set) var rows: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space3
        stack.edgeInsets = NSEdgeInsets(top: Metrics.space3, left: Metrics.space3, bottom: Metrics.space3, right: Metrics.space3)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            widthAnchor.constraint(equalToConstant: Self.width),
        ])
        stack.addArrangedSubview(ActivityJobRow.label(DaemonRecoveryStrings.activityTitle, font: Typography.header, ink: .secondary))
        setAccessibilityIdentifier("cmux.activity.popover.content")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The row views in order (tests read them: an unchanged job keeps its view).
    var rowViews: [ActivityJobRow] { stack.arrangedSubviews.compactMap { $0 as? ActivityJobRow } }

    func update(_ jobs: [LongJob]) {
        rows = jobs.map(ActivityIndicatorView.summary)
        let ids = Set(jobs.map(\.id))
        for (id, row) in rowsByID where !ids.contains(id) {
            row.removeFromSuperview()
            rowsByID[id] = nil
        }
        for (index, job) in jobs.enumerated() {
            let row = rowsByID[job.id] ?? ActivityJobRow()
            rowsByID[job.id] = row
            row.show(job)
            // After the header, in the list's order.
            let place = index + 1
            if row.superview !== stack {
                stack.insertArrangedSubview(row, at: min(place, stack.arrangedSubviews.count))
            } else if stack.arrangedSubviews.firstIndex(of: row) != place {
                stack.removeArrangedSubview(row)
                stack.insertArrangedSubview(row, at: min(place, stack.arrangedSubviews.count))
            }
        }
    }
}

/// One job in the Activity popover: its title, a bar when its size is known, the percent and detail, and,
/// for a job that quitting would interrupt, that quitting restarts it. Updated in place.
final class ActivityJobRow: NSStackView {
    private let title = ActivityJobRow.label("", font: Typography.bodyEmphasized, ink: .primary)
    private let bar = LongJobProgressBar()
    private let detail = ActivityJobRow.label("", font: Typography.caption, ink: .secondary)
    private let quit = ActivityJobRow.label(DaemonRecoveryStrings.activityQuitRestarts, font: Typography.caption, ink: .tertiary)

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: ActivityPopoverView.width - 2 * Metrics.space3).isActive = true
        for view in [title, bar, detail, quit] { addArrangedSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ job: LongJob) {
        if title.stringValue != job.displayTitle { title.stringValue = job.displayTitle }
        if let fraction = job.fraction { bar.set(fraction: fraction) }
        bar.isHidden = job.fraction == nil
        let line = [job.percentText, job.detailText].compactMap(\.self).joined(separator: " · ")
        if detail.stringValue != line { detail.stringValue = line }
        detail.isHidden = line.isEmpty
        quit.isHidden = !job.holds(.quit)
        setAccessibilityLabel([job.displayTitle, line].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    static func label(_ text: String, font: NSFont, ink: ThemeInk) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.ink = ink
        label.preferredMaxLayoutWidth = ActivityPopoverView.width - 2 * Metrics.space3
        return label
    }
}
