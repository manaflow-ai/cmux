import AppKit
import CmuxNextDesign
import QuartzCore

/// A row's state badges (`SidebarRowBadgeStyle`). Each item sits in a whole-point cell so its
/// glyph lands on the pixel grid at 1x and 2x (the 10 pt static glyphs' pixel art). Behind the
/// glyph, a disc of the row's own backdrop color cuts a 1.5 pt ring out of whatever the badge
/// sits on, like an avatar's presence badge.
/// - `corner`: one glyph; the disc hugs it (a dot is `SidebarStyle.statusDotSize`, whatever its color).
/// - `plain`: one glyph in the trailing slot of a row without an icon: the bare glyph, no disc and
///   no ring (Lawrence 2026-10-18: the spinner and the blue dot had "a weird background circle
///   thing"; nothing sits under a trailing glyph, so there is nothing to cut a ring out of).
/// - `stack`: each item is a full chip (a tonal disc with the glyph inside, ringed by the
///   backdrop), and each chip tucks under the one before it only as far as its padding, so every
///   glyph stays whole and the overlap reads as a stack of avatars.
/// A working or loading item's spinner has neither: it draws bare on the row's own background.
/// Glyphs are the shared status indicator: the icon set, colors and Reduce Motion (a still ring
/// for work) follow it.
final class RowBadgeView: NSView {
    enum Look: Equatable { case corner, plain, stack }

    private var glyphs: [StatusIndicatorView] = []
    private var rings: [CALayer] = []
    private var chips: [CALayer] = []
    private(set) var states: [StatusIndicatorState] = []
    private(set) var look = Look.corner
    /// The glyph's side: the static glyphs' 10 pt box, so their 1x pixel art draws as drawn.
    static let glyphSide: CGFloat = 10
    /// Every mark but a dot (the spinner, the red warning, the orange needs-you marks) draws in one
    /// 14 pt box centered in its cell, so the marks read at one size on one column. Leo 2026-11-01:
    /// "a bigger red warn symbol", like ChatGPT (the 14 pt box draws the info ring at about 13 pt),
    /// then "and every icon is still fucking small". The cell, its center and the row's spacing
    /// stay fixed; every dot, blue or orange, paints `SidebarStyle.statusDotSize` (Lawrence msg 19696).
    static var markSide: CGFloat { SidebarStyle.statusMarkSide }
    /// A working or loading spinner draws smaller than the other marks: the row's status glyph size
    /// (`SidebarStyle.statusGlyphSize`, 10 pt compact, 12 comfortable), the box the shared indicator takes
    /// on rows without badges, so it never outweighs the 8 pt unread dot or the row's leading icon. Its
    /// cell stays the same, so nothing moves as work starts or ends. Leo 2026-11-03: "i think the spinners
    /// are maybe a bit too big".
    static var spinnerSide: CGFloat { SidebarStyle.statusSpinnerSide }
    static let ringWidth: CGFloat = 1.5

    /// A dot glyph keeps the 10 pt box its dot tokens are measured in; every other mark takes `markSide`.
    private static func isDot(_ glyph: StatusIndicatorView) -> Bool {
        let drawn = glyph.indicator.plan.glyph
        return drawn == .mark(.vector(.dot)) || drawn == .dot
    }

    /// A working or loading item: the spinner (`spinnerSide`).
    static func isSpinner(_ state: StatusIndicatorState) -> Bool { state.isWorking || state.isLoading }

    /// The room around a glyph in its cell: 2 pt for a corner badge (its 1.5 pt ring and half a
    /// point of air) and a plain glyph (the same cell, so the glyph keeps its place), 4 pt for a
    /// stack chip (2.5 pt of chip, then the ring).
    var cellPad: CGFloat { look == .stack ? 4 : 2 }
    /// Whether any disc (a cutout ring or a stack chip) draws behind a glyph.
    var drawsBackdrop: Bool {
        zip(rings, chips).prefix(states.count).contains { !$0.isHidden || !$1.isHidden }
    }
    var cellSide: CGFloat { Self.glyphSide + 2 * cellPad }
    /// How far each stack cell starts after the one before: it hides only the next chip's padding.
    var step: CGFloat { cellSide - cellPad }
    /// The row's backdrop (its fill over the sidebar's background): the color the rings cut with.
    var ringColor: CGColor = NSColor.clear.cgColor {
        didSet { rings.forEach { $0.backgroundColor = ringColor } }
    }
    /// The stack chips' tone.
    var chipColor: CGColor = NSColor.clear.cgColor {
        didSet { chips.forEach { $0.backgroundColor = chipColor } }
    }

    nonisolated override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The ring and chip layers behind item `index` (test hook).
    func backdrops(at index: Int) -> [CALayer] { [rings[index], chips[index]] }
    /// The glyphs' frames, in order (test hook).
    var glyphFrames: [CGRect] { glyphs.prefix(states.count).map(\.frame) }

    /// The width the badges take: one cell, then each further one's step.
    var preferredWidth: CGFloat {
        states.isEmpty ? 0 : cellSide + CGFloat(states.count - 1) * step
    }

    func configure(_ states: [StatusIndicatorState], look: Look) {
        guard states != self.states || look != self.look else { return }
        (self.states, self.look) = (states, look)
        while glyphs.count < states.count {
            let ring = CALayer(), chip = CALayer()
            ring.backgroundColor = ringColor
            chip.backgroundColor = chipColor
            layer?.addSublayer(ring)
            layer?.addSublayer(chip)
            rings.append(ring)
            chips.append(chip)
            let glyph = StatusIndicatorView()
            glyph.usesStatusColors = true // blue unread, orange attention, red error (Lawrence msg 11983)
            glyph.ignoresScaleSetting = true
            addSubview(glyph)
            glyphs.append(glyph)
        }
        for (index, glyph) in glyphs.enumerated() {
            let shown = index < states.count
            // A spinner is bare on the row's own background (Leo: "the spinner should NOT have a
            // background"); its cell keeps its size, so nothing moves when the work ends.
            let bare = shown && Self.isSpinner(states[index])
            rings[index].isHidden = !shown || look == .plain || bare
            chips[index].isHidden = !shown || look != .stack || bare
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
        let ring = Self.ringWidth
        func disc(_ layer: CALayer, around center: CGPoint, side: CGFloat, z: CGFloat) {
            layer.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            layer.cornerRadius = side / 2
            layer.zPosition = z
        }
        for index in glyphs.indices {
            // Whole points: the cell, so the glyph inside it, sits on the pixel grid.
            let cell = CGRect(x: CGFloat(index) * step, y: ((bounds.height - cellSide) / 2).rounded(), width: cellSide, height: cellSide)
            let side = Self.isDot(glyphs[index]) ? Self.glyphSide
                : Self.isSpinner(glyphs[index].state) ? Self.spinnerSide : Self.markSide
            let center = CGPoint(x: cell.midX, y: cell.midY)
            let glyph = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            // Earlier items stack in front: each cell covers the one after it.
            let z = CGFloat(glyphs.count - index) * 3
            if look == .plain {
                // No disc: the glyph alone.
            } else if look == .corner {
                let mark = Self.isDot(glyphs[index]) ? SidebarStyle.statusDotSize : side
                disc(rings[index], around: center, side: mark + 2 * ring, z: z - 2)
            } else {
                disc(rings[index], around: center, side: cellSide, z: z - 2)
                disc(chips[index], around: center, side: cellSide - 2 * ring, z: z - 1)
            }
            // Every dot (blue unread, orange needs you) paints the one status dot diameter in its box.
            glyphs[index].dotDiameter = SidebarStyle.statusDotSize
            glyphs[index].frame = glyph
            glyphs[index].layer?.zPosition = z
        }
    }
}
