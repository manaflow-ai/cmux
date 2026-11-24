#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): one view inside a rounded fill and an optional border,
/// with padding. Drawn in `draw(_:)`, so dynamic colours follow the window's look and a bitmap of the view
/// (the rendered tests) holds the same pixels as the window.
final class EnvBox: NSView {
    /// The corner shape: a fixed radius, or a capsule (half the height).
    enum Corner {
        case radius(CGFloat)
        case capsule
    }

    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    private let corner: Corner
    private let dash: [CGFloat]?
    private let borderWidth: CGFloat

    /// - Parameters:
    ///   - content: the view inside, or nil for a plain shape (a divider line, a dot).
    ///   - padding: the room between the shape's edge and `content`.
    ///   - fill: the shape's fill; nil draws none.
    ///   - border: an inside border; nil draws none.
    ///   - borderWidth: the border's width in points.
    ///   - corner: the corner radius, or a capsule.
    ///   - dash: a dash pattern for the border.
    init(_ content: NSView?, padding: NSEdgeInsets = NSEdgeInsetsZero, fill: NSColor? = nil, border: NSColor? = nil,
         borderWidth: CGFloat = 1, corner: Corner = .radius(0), dash: [CGFloat]? = nil) {
        self.fill = fill
        self.border = border
        self.corner = corner
        self.dash = dash
        self.borderWidth = borderWidth
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        guard let content else { return }
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = switch corner {
        case let .radius(value): value
        case .capsule: bounds.height / 2
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        if let border {
            border.setStroke()
            let half = borderWidth / 2
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: half, dy: half), xRadius: max(radius - half, 0), yRadius: max(radius - half, 0))
            path.lineWidth = borderWidth
            if let dash { path.setLineDash(dash, count: dash.count, phase: 0) }
            path.stroke()
        }
    }
}

/// Uniform padding: `all` on every side.
func envPad(_ all: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top: all, left: all, bottom: all, right: all) }

/// Padding by axis: `h` left and right, `v` top and bottom.
func envPad(h: CGFloat, v: CGFloat) -> NSEdgeInsets { NSEdgeInsets(top: v, left: h, bottom: v, right: h) }
#endif
