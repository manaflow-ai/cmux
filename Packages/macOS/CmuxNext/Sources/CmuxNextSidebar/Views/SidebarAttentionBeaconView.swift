import AppKit
import CmuxNextDesign

/// The loud-rows look's edge beacon (`SidebarNotificationEmphasis.loudRows`): a solid capsule at the list's
/// top or bottom edge, in the most urgent color, saying how many workspaces with a notification are scrolled
/// out of view that way ("↑ 2 above"); a click scrolls to the nearest and flashes it. Hidden at 0.
final class SidebarAttentionBeaconView: NSView {
    enum Edge { case top, bottom }

    let edge: Edge
    var onClick: (() -> Void)?
    private(set) var count = 0
    private(set) var kind: WorkspaceRowAttention.Kind?
    private let label = SidebarRowView.label(font: NSFont.systemFont(ofSize: SidebarStyle.subtitleFont.pointSize, weight: TypeScale.emphasis))

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 4
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func show(count: Int, kind: WorkspaceRowAttention.Kind?) {
        guard count != self.count || kind != self.kind else { return }
        (self.count, self.kind) = (count, kind)
        isHidden = count == 0 || kind == nil
        let text = edge == .top ? Strings.attentionAbove(count) : Strings.attentionBelow(count)
        label.setString(text)
        setAccessibilityLabel(text)
        tint()
        needsLayout = true
    }

    var preferredSize: NSSize {
        let size = label.naturalSize
        return NSSize(width: ceil(size.width) + 2 * Metrics.space3, height: ceil(size.height) + Metrics.space2)
    }

    func tint() {
        performWithTheme {
            layer?.backgroundColor = (kind.map(SidebarAttentionShelfView.color) ?? Palette.statusUnread).cgColor
            label.setColor(.white)
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let size = label.naturalSize
        label.frame = NSRect(x: (bounds.width - ceil(size.width)) / 2, y: (bounds.height - ceil(size.height)) / 2,
                             width: ceil(size.width), height: ceil(size.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return onClick != nil
    }
}
