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

    func show(relativeTo anchor: NSView) {
        guard let window = anchor.window else { return }
        popup.panel.adoptThemeScope(of: anchor)
        card.applyTheme()
        popup.keepsOpen = { [weak anchor] event in
            guard let anchor, event.window === anchor.window else { return false }
            return anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        let rect = window.convertToScreen(anchor.convert(CmuxPopoverAnchor.rect(in: anchor), to: nil))
        content.layoutSubtreeIfNeeded()
        let size = CGSize(width: ActivityPopoverView.width, height: ceil(content.fittingSize.height))
        guard popup.show(size: size, anchor: rect, in: window, preferred: .below, centered: true, makeKey: true) != nil else { return }
        popup.panel.makeFirstResponder(nil)
    }

    func close() { popup.hide() }

    func closePanel() { popup.closePanel() }
}

/// The popover's rows, rebuilt from each list (a few jobs, changing a few times a second at most).
final class ActivityPopoverView: NSView {
    static let width: CGFloat = 320
    private let stack = NSStackView()
    private(set) var rows: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Metrics.space2
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
        setAccessibilityIdentifier("cmux.activity.popover.content")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ jobs: [LongJob]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.addArrangedSubview(label(DaemonRecoveryStrings.activityTitle, font: Typography.header, ink: .secondary))
        rows = jobs.map(ActivityIndicatorView.summary)
        for job in jobs {
            stack.addArrangedSubview(label(job.displayTitle, font: Typography.bodyEmphasized, ink: .primary))
            if let fraction = job.fraction {
                let bar = LongJobProgressBar()
                bar.set(fraction: fraction)
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: Self.width - 2 * Metrics.space3).isActive = true
                stack.addArrangedSubview(bar)
            }
            let line = [job.percentText, job.detailText].compactMap(\.self).joined(separator: " · ")
            if !line.isEmpty { stack.addArrangedSubview(label(line, font: Typography.caption, ink: .secondary)) }
            if job.holds(.quit) || job.holds(.startup) {
                stack.addArrangedSubview(label(DaemonRecoveryStrings.activityQuitRestarts, font: Typography.caption, ink: .tertiary))
            }
        }
    }

    private func label(_ text: String, font: NSFont, ink: ThemeInk) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.ink = ink
        label.preferredMaxLayoutWidth = Self.width - 2 * Metrics.space3
        return label
    }
}
