import AppKit
import CmuxNextDesign
import QuartzCore

/// A row's state badges (`SidebarRowBadgeStyle`): status glyphs on discs of the row's own backdrop
/// color, so each one cuts a thin ring out of what it sits on (the leading icon, or the glyph
/// before it in a stack), like an avatar's presence badge. The first glyph is frontmost; each
/// after it tucks under its neighbor by `overlap` of a disc. Glyphs are the shared status
/// indicator, so the icon set, the colors and Reduce Motion (a still ring for work) all follow it.
final class RowBadgeView: NSView {
    private var glyphs: [StatusIndicatorView] = []
    private var discs: [CALayer] = []
    private(set) var states: [StatusIndicatorState] = []
    /// The side of one glyph.
    var glyphSide: CGFloat = 8 { didSet { if glyphSide != oldValue { needsLayout = true } } }
    /// The width of the cutout ring around each glyph.
    var ringWidth: CGFloat = 1.5 { didSet { if ringWidth != oldValue { needsLayout = true } } }
    /// How much of a disc the next one in a stack hides.
    static let overlap: CGFloat = 0.4
    /// The row's backdrop (its fill over the sidebar's background): the color the rings cut with.
    var ringColor: CGColor = NSColor.clear.cgColor {
        didSet { discs.forEach { $0.backgroundColor = ringColor } }
    }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// One disc: the glyph plus its ring.
    var discSide: CGFloat { glyphSide + 2 * ringWidth }

    /// The width the badges take: one disc, then each further one's unhidden part.
    var preferredWidth: CGFloat {
        states.isEmpty ? 0 : discSide + CGFloat(states.count - 1) * discSide * (1 - Self.overlap)
    }

    func configure(_ states: [StatusIndicatorState]) {
        guard states != self.states else { return }
        self.states = states
        while glyphs.count < states.count {
            let disc = CALayer()
            disc.backgroundColor = ringColor
            layer?.addSublayer(disc)
            discs.append(disc)
            let glyph = StatusIndicatorView()
            glyph.ignoresScaleSetting = true
            addSubview(glyph)
            glyphs.append(glyph)
        }
        for (index, glyph) in glyphs.enumerated() {
            let shown = index < states.count
            discs[index].isHidden = !shown
            glyph.configure(shown ? states[index] : .idle)
        }
        isHidden = states.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = window?.backingScaleFactor ?? 2
        func snapped(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let side = discSide, step = discSide * (1 - Self.overlap)
        let top = snapped((bounds.height - side) / 2)
        for index in glyphs.indices {
            let x = snapped(CGFloat(index) * step)
            // Earlier items stack in front: each disc covers the one after it.
            let z = CGFloat(glyphs.count - index) * 2
            discs[index].frame = CGRect(x: x, y: top, width: side, height: side)
            discs[index].cornerRadius = side / 2
            discs[index].zPosition = z - 1
            glyphs[index].frame = NSRect(x: x + ringWidth, y: top + ringWidth, width: glyphSide, height: glyphSide)
            glyphs[index].layer?.zPosition = z
        }
    }
}
