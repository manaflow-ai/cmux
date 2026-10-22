import AppKit
import CmuxNextDesign

/// Where a drag's drop goes, drawn over the list (nested-groups prototype): an outline round the
/// whole group block a drop goes into, or a line at the level a drop between rows lands at.
///
/// The two never look alike: "inside" is a tinted, outlined block with the group's header in it;
/// "between" is a thin line with a dot at its leading end, at the x of the rows it joins
/// (`SidebarIndent`), so its level shows before the drop.
final class SidebarNestedDropIndicatorView: NSView {
    /// What the indicator shows.
    enum Mark: Equatable {
        /// A drop into a group: `frame` is its header and every row of its subtree.
        case into(frame: CGRect, color: NSColor)
        /// A drop between rows: the line's leading point and its width.
        case between(origin: CGPoint, width: CGFloat, color: NSColor)
    }

    var mark: Mark? {
        didSet { if mark != oldValue { update() } }
    }

    private let outline = CAShapeLayer()
    private let line = CAShapeLayer()
    private let dot = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [outline, line, dot] {
            layer.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "opacity": NSNull()]
            self.layer?.addSublayer(layer)
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func update() {
        outline.isHidden = true
        line.isHidden = true
        dot.isHidden = true
        switch mark {
        case let .into(frame, color):
            outline.isHidden = false
            let rect = frame.insetBy(dx: 0.75, dy: 0.75)
            outline.path = CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil)
            outline.lineWidth = 1.5
            outline.strokeColor = color.withAlphaComponent(0.9).cgColor
            outline.fillColor = color.withAlphaComponent(0.1).cgColor
        case let .between(origin, width, color):
            line.isHidden = false
            dot.isHidden = false
            let radius: CGFloat = 3.5
            let path = CGMutablePath()
            path.move(to: CGPoint(x: origin.x + radius * 2, y: origin.y))
            path.addLine(to: CGPoint(x: origin.x + width, y: origin.y))
            line.path = path
            line.lineWidth = 2
            line.lineCap = .round
            line.strokeColor = color.cgColor
            line.fillColor = nil
            dot.path = CGPath(ellipseIn: CGRect(x: origin.x, y: origin.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            dot.lineWidth = 2
            dot.strokeColor = color.cgColor
            dot.fillColor = NSColor.clear.cgColor
        case nil:
            break
        }
    }
}
