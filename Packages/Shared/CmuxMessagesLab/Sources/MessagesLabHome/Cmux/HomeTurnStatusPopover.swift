import AppKit

/// The details of the Chief's running turn, opened by a click on its status line
/// (the "working on" line above the typing dots): each step so far with its
/// duration, the running one counting live, and the turn's time so far. A
/// transient popover: a click outside or Esc closes it, and the field gets the
/// keyboard back.
@MainActor
final class HomeTurnStatusPopover: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let content = HomeTurnStatusView()
    private let details: () -> HomeTurnDetails?
    /// After the popover closed: the composer takes the keyboard again.
    var onClosed: (() -> Void)?

    init(details: @escaping () -> HomeTurnDetails?) {
        self.details = details
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
    }

    var isShown: Bool { popover.isShown }

    /// Shows the details under `rect` (in `view`), or closes them when shown (the line toggles).
    func toggle(relativeTo rect: CGRect, of view: NSView) {
        if popover.isShown { return close() }
        guard let now = details() else { return }
        content.show(now)
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// The clock ticked or a step began: the open list counts on.
    func refresh() {
        guard popover.isShown else { return }
        guard let now = details() else { return close() }
        content.show(now)
        popover.contentSize = content.fittingSize
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// AppKit calls it on the main actor (NSPopoverDelegate's `NS_SWIFT_UI_ACTOR`).
    func popoverDidClose(_ notification: Notification) {
        onClosed?()
    }
}

/// The popover's list: a title with the turn's total, then one row per step
/// (its line, then its duration or "now"). Plain labels, so VoiceOver reads them.
@MainActor
final class HomeTurnStatusView: NSView {
    private let stack = NSStackView()
    private var shown: HomeTurnDetails?
    /// Most rows shown; the oldest beyond it are summarized by the total.
    static let visibleRows = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        setAccessibilityRole(.list)
        setAccessibilityLabel(CmuxStrings.turnTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ details: HomeTurnDetails) {
        guard details != shown else { return }
        shown = details
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        let title = label(CmuxStrings.turnTitle, size: 12, weight: .semibold, color: .labelColor)
        let total = label(CmuxStrings.turnTotal(Self.duration(details.total)), size: 11, weight: .regular, color: .secondaryLabelColor)
        addRow(title, total)
        for step in details.steps.suffix(Self.visibleRows) {
            let line = label(step.line, size: 11, weight: step.running ? .medium : .regular,
                             color: step.running ? .labelColor : .secondaryLabelColor)
            line.lineBreakMode = .byTruncatingTail
            line.toolTip = step.line
            let time = step.running ? "\(Self.duration(step.duration)) · \(CmuxStrings.turnNow)" : Self.duration(step.duration)
            addRow(line, label(time, size: 11, weight: .regular, color: .tertiaryLabelColor, mono: true))
        }
    }

    /// "4s", "1m 5s"; "<1s" under a second.
    static func duration(_ interval: TimeInterval) -> String {
        HomeLiveLine.elapsed(interval) ?? CmuxStrings.turnUnderOneSecond
    }

    private func addRow(_ left: NSTextField, _ right: NSTextField) {
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        left.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [left, spacer, right])
        row.orientation = .horizontal
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.staticText)
        row.setAccessibilityLabel("\(left.stringValue), \(right.stringValue)")
        stack.addArrangedSubview(row)
        // Full width of the list (inside its insets), so each time sits at the right edge.
        row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? HomeFonts.monospacedDigit(ofSize: size, weight: weight) : HomeFonts.system(ofSize: size, weight: weight)
        field.textColor = color
        field.setAccessibilityElement(false)
        return field
    }
}
