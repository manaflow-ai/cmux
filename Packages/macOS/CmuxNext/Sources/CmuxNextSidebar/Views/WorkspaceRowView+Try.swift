import AppKit
import CmuxNextDesign

/// A workspace row's Try pill: the workspace's agent finished something to try (acpmux `tryIt`, its
/// wrap-up's `try`), and one click opens it in that workspace: a page in a browser tab (a Tag Opener
/// address launches its build) or a command in a new terminal (``SidebarSessionTree/onTry``). Its
/// tooltip names what it opens and lists the Verify steps. Quiet like the keycap: a hairline pill
/// with "▶ Try" in the secondary color, filled while the pointer is on it. Aziz, 2026-11-09: "since
/// all workspaces are units of tasks, make it so that whenever a workspace agent finished its task,
/// theres a direct way for me to try out and verify its work in addition to the artifact."
final class SidebarTryPillView: NSView {
    private let text = SidebarRowView.label(font: SidebarStyle.badgeFont)
    private(set) var tryIt: SidebarTry?
    private var workspace: WorkspaceID?
    private var tracking: NSTrackingArea?
    private var pointedAt = false { didSet { if pointedAt != oldValue { tint() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        text.alignment = .center
        addSubview(text)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ tryIt: SidebarTry?, workspace: WorkspaceID) {
        let shows = tryIt.map { $0.url != nil || $0.command != nil } == true && SidebarSessionTree.shared.onTry != nil
        self.tryIt = shows ? tryIt : nil
        self.workspace = workspace
        isHidden = !shows
        guard let tryIt, shows else {
            themedToolTip = nil
            pointedAt = false
            return
        }
        text.setString(Strings.tryPill)
        themedToolTip = Self.toolTip(tryIt)
        setAccessibilityLabel(Strings.tryPillLabel(tryIt.label))
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The label, what it opens, then each Verify step on its own line.
    static func toolTip(_ tryIt: SidebarTry) -> String {
        var lines = [tryIt.label]
        if let target = tryIt.url ?? tryIt.command { lines.append(target) }
        lines += tryIt.verify.map { "☐ " + $0 }
        return lines.joined(separator: "\n")
    }

    func tint() {
        text.setColor(pointedAt ? Palette.textPrimary : Palette.textSecondary)
        layer?.borderColor = Palette.separator.cgColor
        layer?.borderWidth = Metrics.lineWidth(1)
        layer?.cornerRadius = Metrics.controlCornerRadius
        layer?.backgroundColor = pointedAt ? Palette.separator.cgColor : nil
    }

    override var intrinsicContentSize: NSSize {
        let label = text.naturalSize
        return NSSize(width: ceil(label.width + 2 * Metrics.space1 + Metrics.space1),
                      height: ceil(SidebarStyle.badgeFont.pointSize + Metrics.space2))
    }

    override func layout() {
        super.layout()
        let label = text.naturalSize
        text.frame = NSRect(x: 0, y: (bounds.height - label.height) / 2, width: bounds.width, height: ceil(label.height))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { pointedAt = true }
    override func mouseExited(with event: NSEvent) { pointedAt = false }

    /// The click is the pill's own: it never selects the row under it.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        open()
    }

    override func accessibilityPerformPress() -> Bool {
        open()
        return tryIt != nil
    }

    private func open() {
        guard let tryIt, let workspace, let onTry = SidebarSessionTree.shared.onTry else { return }
        onTry(workspace, tryIt)
    }
}

extension WorkspaceRowView {
    func configureTry(_ tryIt: SidebarTry?, workspace: WorkspaceID) {
        tryPill.configure(tryIt, workspace: workspace)
    }

    /// The Try pill, right to left from `trailing`; the next trailing edge.
    func layoutTry(trailing: CGFloat, cy: CGFloat) -> CGFloat {
        guard !tryPill.isHidden else { return trailing }
        let size = tryPill.intrinsicContentSize
        let columns = SidebarStyle.columns(rowWidth: layoutBounds.width)
        tryPill.frame = columns.trailingFrame(before: trailing, centerY: cy, size: size)
        return columns.trailingEdge(before: tryPill.frame)
    }
}

extension Strings {
    /// The Try pill's words.
    static var tryPill: String {
        String(localized: "sidebar.try.pill", defaultValue: "▶ Try", bundle: .module)
    }

    /// The Try pill for VoiceOver: what it opens, as the agent named it.
    static func tryPillLabel(_ label: String) -> String {
        String(localized: "sidebar.try.a11y", defaultValue: "Try: \(label)", bundle: .module)
    }
}
