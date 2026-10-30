import AppKit
import CmuxNextDesign
import CmuxNextHostPressure

/// The host pressure popover under the top-row indicator: what the host is at
/// against its budget, acpmux's turns and processes, its busiest sessions with
/// Stop (asked first; the session stays to resume), and Open Agent Activity. A
/// popup of the shared native host, like Chief Settings: it closes on a click
/// outside, Escape, the indicator again, or the window moving away.
@MainActor
final class HostPressurePopover {
    let content = HostPressurePopoverView()
    private let popup = NativePopupHost(panel: NativePopupPanel(identifier: "cmux.hostPressure.popover"))
    private let card: OverlaySurfaceView

    init() {
        card = Glass.makeOverlayPanel(content: content, cornerRadius: PopupStyle.standard.cornerRadius)
        popup.panel.adoptPopupStyle(card: card)
    }

    var isShown: Bool { popup.isShown }

    /// Opens under `anchor` (the indicator), which toggles it closed again.
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
        let size = CGSize(width: HostPressurePopoverView.width, height: ceil(content.fittingSize.height))
        guard popup.show(size: size, anchor: rect, in: window, preferred: .below, centered: true, makeKey: true) != nil else { return }
        popup.panel.makeFirstResponder(nil)
    }

    func close() { popup.hide() }

    /// Closes the panel for good (its indicator left its window).
    func closePanel() { popup.closePanel() }
}

/// The popover's content, rebuilt from each verdict (a few rows; it changes only on a level change or a stop).
final class HostPressurePopoverView: NSView {
    static let width: CGFloat = 320
    var onStop: ((HostBudgetSession) -> Void)?
    var onOpenActivity: (() -> Void)?
    private let stack = NSStackView()

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
        setAccessibilityIdentifier("cmux.hostPressure.popover.content")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `canStop`: whether its sessions are real (a forced level's samples get no Stop).
    func update(level: HostPressureLevel, verdict: HostBudgetVerdict?, canStop: Bool = true) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let title = level == .critical ? HostPressureStrings.criticalTitle : HostPressureStrings.warningTitle
        stack.addArrangedSubview(label(title, font: Typography.bodyEmphasized, ink: .primary))
        if let verdict {
            for line in Self.reasons(verdict) { stack.addArrangedSubview(label(line, font: Typography.caption, ink: .secondary)) }
            if let turns = verdict.localTurns, let processes = verdict.backgroundProcesses {
                stack.addArrangedSubview(row([label(HostPressureStrings.turns, font: Typography.caption, ink: .secondary),
                                              label(turns.formatted(), font: Typography.caption, ink: .primary),
                                              label(HostPressureStrings.processes, font: Typography.caption, ink: .secondary),
                                              label(processes.formatted(), font: Typography.caption, ink: .primary)]))
            }
            if let top = verdict.top, !top.isEmpty { addSessions(top, canStop: canStop) }
        }
        stack.addArrangedSubview(label(HostPressureStrings.warnOnly, font: Typography.caption, ink: .tertiary))
        let activity = ThemedBezelButton(title: HostPressureStrings.openActivity, target: self, action: #selector(openActivity))
        activity.controlSize = .small
        activity.setAccessibilityIdentifier("cmux.hostPressure.openActivity")
        stack.addArrangedSubview(activity)
    }

    /// The load against its limit first, then acpmux's other reasons in its words.
    static func reasons(_ verdict: HostBudgetVerdict) -> [String] {
        let load = verdict.load1.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–"
        let limit = verdict.loadLimit.formatted(.number.precision(.fractionLength(0 ... 1)))
        return [HostPressureStrings.load(load, limit: limit)] + verdict.over.filter { !$0.hasPrefix("load1 ") }
    }

    private func addSessions(_ sessions: [HostBudgetSession], canStop: Bool) {
        stack.addArrangedSubview(label(HostPressureStrings.sessions, font: Typography.header, ink: .secondary))
        let grid = NSGridView(views: [[label("", font: Typography.caption, ink: .tertiary),
                                       label(HostPressureStrings.turns, font: Typography.caption, ink: .tertiary),
                                       label(HostPressureStrings.processes, font: Typography.caption, ink: .tertiary), NSView()]])
        for session in sessions {
            let stop = ThemedBezelButton(title: HostPressureStrings.stop, target: self, action: #selector(stop(_:)))
            stop.isHidden = !canStop
            stop.controlSize = .small
            stop.identifier = NSUserInterfaceItemIdentifier(session.sessionId)
            stop.setAccessibilityIdentifier("cmux.hostPressure.stop.\(session.name)")
            let name = label(session.name, font: Typography.body, ink: .primary)
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [name, label(session.turns.formatted(), font: Typography.caption, ink: .secondary),
                               label(session.processes.formatted(), font: Typography.caption, ink: .secondary), stop])
        }
        grid.columnSpacing = Metrics.space3
        grid.rowSpacing = Metrics.space1
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).width = 150
        sessionsByID = Dictionary(sessions.map { ($0.sessionId, $0) }) { first, _ in first }
        stack.addArrangedSubview(grid)
    }

    private var sessionsByID: [String: HostBudgetSession] = [:]

    @objc private func stop(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let session = sessionsByID[id] else { return }
        onStop?(session)
    }

    @objc private func openActivity() { onOpenActivity?() }

    private func label(_ text: String, font: NSFont, ink: ThemeInk) -> ThemedLabel {
        let label = ThemedLabel(wrappingLabelWithString: text)
        label.font = font
        label.ink = ink
        label.preferredMaxLayoutWidth = Self.width - 2 * Metrics.space3
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.spacing = Metrics.space2
        return row
    }
}
