import AppKit
import CmuxNextDesign

/// Each open group's members' line (cx-qno.17, cx-q5jw) as one view under
/// the rows. The lines animate in the rows' own spring block (`RowMotion`),
/// so a line's end tracks its group's last row in every frame and never runs
/// past it (cx-ai79); a Core Animation spring beside the rows' AppKit spring
/// drifted apart from them.
@MainActor
final class SidebarGroupLineViews {
    private var views: [GroupID: GroupLineView] = [:]
    /// Lines of closed or gone groups while they shrink and fade out.
    private var leavingViews: [NSView] = []

    /// The changes that move the lines to `new`, to run inside the rows'
    /// animation block, and the views to remove when it ends. A kept line
    /// moves to its new frame, a new one starts at `start` (the line over
    /// its rows' start frames) so both its ends move with the rows, and a
    /// line whose group closed or left shrinks back up into its header.
    func update(_ new: [SidebarGroupLine], from start: [SidebarGroupLine], in list: NSView, above decorations: NSView, animated: Bool) -> (changes: () -> Void, leaving: [NSView]) {
        var gone = views
        let starts = Dictionary(start.map { ($0.group, $0.frame) }, uniquingKeysWith: { first, _ in first })
        var moves: [(GroupLineView, CGRect)] = []
        for line in new {
            gone[line.group] = nil
            let view = views[line.group] ?? {
                let view = GroupLineView()
                list.addSubview(view, positioned: .above, relativeTo: decorations)
                views[line.group] = view
                Motion.withoutAnimation {
                    view.frame = animated ? starts[line.group] ?? Self.top(of: line.frame) : line.frame
                    // Fades in with its header, so it never shows over the
                    // members' fills before they indent.
                    view.alphaValue = animated ? 0 : 1
                }
                return view
            }()
            view.color = line.color
            moves.append((view, line.frame))
        }
        var leaving: [(GroupLineView, CGRect)] = []
        for (group, view) in gone {
            views[group] = nil
            leaving.append((view, Self.top(of: view.frame)))
        }
        leavingViews.removeAll { $0.superview == nil }
        leavingViews += leaving.map(\.0)
        let changes = {
            for (view, frame) in moves {
                view.animator().frame = frame
                view.animator().alphaValue = 1
            }
            for (view, frame) in leaving {
                view.animator().frame = frame
                view.animator().alphaValue = 0
            }
        }
        return (changes, leaving.map(\.0))
    }

    /// Moves every line by `dy` at once, with the rows and the scroll offset.
    func shift(by dy: CGFloat) {
        for view in views.values { view.frame.origin.y += dy }
        // A line still fading out would stay at the old offset: it goes now.
        leavingViews.forEach { $0.removeFromSuperview() }
        leavingViews.removeAll()
    }

    /// A line's zero-height start: its top edge, under the header bar.
    private static func top(of frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 0)
    }
}

/// One members' line: a rounded bar in its group's header color.
final class GroupLineView: NSView {
    var color: GroupTint = .palette(.grey) {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    override func updateLayer() {
        performWithTheme { layer?.backgroundColor = color.headerFill.cgColor }
    }
}
