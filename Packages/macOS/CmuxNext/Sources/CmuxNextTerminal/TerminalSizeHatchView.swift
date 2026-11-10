import AppKit
import CmuxNextDesign

/// The pane space a terminal does not use while another view sets its grid ("Sized for"): classic's
/// hatch (`TerminalSizeBoundsOverlayView`), 0.5 pt lines rising at 45° every 8 pt in the split
/// divider's color at 60%, and a 1 pt divider-colored border on the grid's sides that face it.
///
/// Drawn by Core Animation, never in `draw(_:)`: one shape layer holds the lines for a size rounded
/// up to ``pathQuantum`` (rebuilt only when the pane grows past it), and an even-odd mask cuts the grid
/// out of it, so a resize or a grid change moves two small paths and redraws nothing per frame.
/// Takes no clicks.
final class TerminalSizeHatchView: NSView {
    /// The lines' horizontal spacing (classic's 8 pt).
    static let spacing: CGFloat = 8
    /// The lines' width (classic's 0.5 pt).
    static let lineWidth: CGFloat = 0.5
    /// The hatch's opacity over the divider color (classic's `BonsplitSizingChromePalette.hatchOpacity`).
    static let hatchOpacity: CGFloat = 0.6
    /// The line path covers the view's size rounded up to this, so most resizes reuse it.
    static let pathQuantum: CGFloat = 512

    private let lines = CAShapeLayer()
    private let hole = CAShapeLayer()
    private let border = CAShapeLayer()
    private var linesSize: CGSize = .zero
    /// The grid's rect in this view (y up), nil while hidden.
    private(set) var gridRect: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        let still: [String: any CAAction] = ["path": NSNull(), "strokeColor": NSNull(), "hidden": NSNull(),
                                             "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        for shape in [lines, hole, border] { shape.actions = still }
        lines.fillColor = nil
        lines.lineWidth = Self.lineWidth
        hole.fillRule = .evenOdd
        hole.fillColor = NSColor.black.cgColor
        lines.mask = hole
        border.fillColor = nil
        border.lineWidth = 1
        layer?.addSublayer(lines)
        layer?.addSublayer(border)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemeColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyThemeColors()
    }

    /// Hatches this view outside `grid` (in this view, y up); nil hides it.
    func show(grid: CGRect?) {
        gridRect = grid
        guard let grid else {
            isHidden = true
            return
        }
        isHidden = false
        let bounds = self.bounds
        let needed = CGSize(width: Self.quantized(bounds.width), height: Self.quantized(bounds.height))
        if needed.width > linesSize.width || needed.height > linesSize.height {
            linesSize = CGSize(width: max(needed.width, linesSize.width), height: max(needed.height, linesSize.height))
            lines.path = Self.linesPath(size: linesSize)
        }
        lines.frame = CGRect(origin: .zero, size: linesSize)
        hole.frame = lines.bounds
        let mask = CGMutablePath()
        mask.addRect(bounds)
        mask.addRect(grid)
        hole.path = mask
        border.frame = bounds
        border.path = Self.borderPath(grid: grid, in: bounds)
    }

    private func applyThemeColors() {
        performWithTheme {
            let divider = Palette.surfaceOverride(.splitDivider) ?? Palette.separator
            let line = divider.usingColorSpace(.sRGB) ?? divider
            lines.strokeColor = line.withAlphaComponent(line.alphaComponent * Self.hatchOpacity).cgColor
            border.strokeColor = line.cgColor
        }
    }

    private static func quantized(_ length: CGFloat) -> CGFloat {
        max(pathQuantum, (length / pathQuantum).rounded(.up) * pathQuantum)
    }

    /// Lines rising at 45° every ``spacing`` points across `size` (y up), starting left of it so the
    /// whole rect is covered.
    static func linesPath(size: CGSize) -> CGPath {
        let path = CGMutablePath()
        var x = -size.height
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
            x += spacing
        }
        return path
    }

    /// A 1 pt line on the grid's sides that face hatch (classic draws none on a side flush with the pane).
    static func borderPath(grid: CGRect, in bounds: CGRect) -> CGPath {
        let path = CGMutablePath()
        let edge = grid.insetBy(dx: 0.5, dy: 0.5)
        if grid.maxX < bounds.maxX - 0.5 {
            path.move(to: CGPoint(x: edge.maxX, y: max(edge.minY, bounds.minY)))
            path.addLine(to: CGPoint(x: edge.maxX, y: min(edge.maxY, bounds.maxY)))
        }
        if grid.minY > bounds.minY + 0.5 {
            path.move(to: CGPoint(x: max(edge.minX, bounds.minX), y: edge.minY))
            path.addLine(to: CGPoint(x: min(edge.maxX, bounds.maxX), y: edge.minY))
        }
        return path
    }
}
