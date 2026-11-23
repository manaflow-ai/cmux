#if os(iOS)
import CmuxMobileDesign
import QuartzCore
import UIKit

/// Smooths a full-screen app's scroll (Leo, 2026-11-23: "smooth out the jaggedness of scroll that we
/// have in claude in terminal vs in regular shell terminal").
///
/// While the finger scrolls the app (from each wheel report until ``watch`` after the last), every
/// presented frame's rows are matched to the previous frame's (``TerminalTUIRowMove``). When the app
/// moved its rows, the band that moved is drawn where the last frame's rows were and glides to its
/// place (``TerminalTUIRowGlide``) a few points per display frame, so the rows move as a shell's
/// scrollback does instead of standing still and then jumping three rows.
///
/// The glide is drawn on a layer over Ghostty's own, inside the surface: the presented frame's band
/// (the same IOSurface, cropped, no draw) at the glide's offset, and the edge rows the last frame
/// showed (a copy of a few pixel rows) in the gap it leaves. At rest the layer is hidden and the
/// frame shows as presented.
@MainActor
final class TerminalTUISmoother {
    /// The surface, its row height (points), its pixels per point and the app's screen rows, or
    /// nil while the surface is not showing a full-screen app.
    var geometry: () -> (surface: TerminalSurfaceView, rowHeight: CGFloat, scale: CGFloat, rows: Int)? = { nil }

    /// Points the content moved since the app's screen came up (the rows it moved, as presented).
    private(set) var travel: CGFloat = 0
    /// The last presented frame's row hashes while watching.
    private var rows: [UInt64]?
    private var watchUntil: CFTimeInterval = 0
    /// Frames are watched this long after the last wheel report (the app's reply on a slow link).
    static let watch: CFTimeInterval = 0.8

    private(set) var glide = TerminalTUIRowGlide()
    /// The band gliding now, and the rows it moved.
    private var move: TerminalTUIRowMove?
    /// The last move's band: the rows whose edges are kept for the next move's gap.
    private var lastBand: Range<Int>?
    /// The last presented frame's rows at each edge of ``lastBand`` (copies), and the frame they
    /// fill in the gap of the next move, with the edge rows of the frame on screen.
    private var edges: (top: TerminalPresentedCopy?, bottom: TerminalPresentedCopy?, rows: Int) = (nil, nil, 0)
    private var gap: TerminalPresentedCopy?
    private var token: FrameClock.Token?
    private var lastTick: CFTimeInterval?

    private let container = CALayer()
    private let current = CALayer()
    private let previous = CALayer()

    init() {
        container.masksToBounds = true
        container.isHidden = true
        container.addSublayer(current)
        container.addSublayer(previous)
        for layer in [container, current, previous] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "contents": NSNull(),
                             "contentsRect": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        }
    }

    /// A wheel report went to the app: watch its frames, from the frame on screen now.
    func wheelSent() {
        watchUntil = CACurrentMediaTime() + Self.watch
        if rows == nil, let frame = read() {
            rows = frame.rows
            keepEdges()
        }
    }

    /// A frame was presented (the screen's present handler, in the transaction that shows it).
    func presented() {
        guard CACurrentMediaTime() < watchUntil, let frame = read() else {
            rows = nil
            if glide.isGliding || !container.isHidden { stop() }
            return
        }
        let previousRows = rows
        rows = frame.rows
        let gapRows = edges
        defer { keepEdges() }
        guard let previousRows else { return }
        guard let move = TerminalTUIRowMove.between(previous: previousRows, current: frame.rows, rows: 0..<frame.screenRows) else {
            // A redraw in place (a spinner) keeps gliding on the new frame; any other change in
            // the band is the app drawing something else there: show it as it is.
            if let gliding = self.move, frame.rows[gliding.band.clamped(to: 0..<frame.rows.count)]
                != previousRows[gliding.band.clamped(to: 0..<previousRows.count)] {
                stop()
            } else {
                draw()
            }
            return
        }
        travel += CGFloat(move.rows) * frame.rowHeight
        // The gap the band leaves is the last frame's rows past the band's far edge: the bottom
        // rows when the content moved down, the top rows when it moved up.
        gap = lastBand == move.band && abs(move.rows) <= gapRows.rows ? (move.rows > 0 ? gapRows.bottom : gapRows.top) : nil
        lastBand = move.band
        self.move = move
        glide.jumped(rows: move.rows, rowHeight: frame.rowPoints, at: CACurrentMediaTime())
        draw()
        startClock()
    }

    /// Where the content is drawn now (points, positive down): the bench's position.
    var contentY: CGFloat { travel + glide.offset }

    /// The app's screen went away (or the page did).
    func reset() {
        rows = nil
        watchUntil = 0
        lastBand = nil
        edges = (nil, nil, 0)
        stop()
    }

    // MARK: - Drawing

    private func stop() {
        glide.stop()
        move = nil
        gap = nil
        stopClock()
        draw()
    }

    private func startClock() {
        guard token == nil else { return }
        lastTick = nil
        token = FrameClock.shared.subscribe { [weak self] tick in
            guard let self else { return }
            let dt = self.lastTick.map { tick.timestamp - $0 } ?? tick.nominal
            self.lastTick = tick.timestamp
            if !self.glide.step(dt: dt) {
                self.move = nil
                self.gap = nil
                self.stopClock()
            }
            self.draw()
        }
    }

    private func stopClock() {
        if let token { FrameClock.shared.unsubscribe(token) }
        token = nil
        lastTick = nil
    }

    /// Draws the band at the glide's offset over the presented frame, or hides the layer at rest.
    private func draw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard glide.isGliding, let move, let geometry = geometry(),
              let frameLayer = geometry.surface.layer.sublayers?.first(where: { $0 !== container }),
              let contents = frameLayer.contents, frameLayer.frame.height > 0,
              let pixels = Self.pixelHeight(contents), pixels > 0 else {
            container.isHidden = true
            current.contents = nil
            previous.contents = nil
            return
        }
        if container.superlayer !== geometry.surface.layer {
            container.removeFromSuperlayer()
            geometry.surface.layer.insertSublayer(container, above: frameLayer)
        }
        let rowPixels = CGFloat(Self.rowPixels(geometry))
        let pointsPerPixel = frameLayer.frame.height / CGFloat(pixels)
        let rowPoints = rowPixels * pointsPerPixel
        let band = CGRect(x: frameLayer.frame.minX, y: frameLayer.frame.minY + CGFloat(move.band.lowerBound) * rowPoints,
                          width: frameLayer.frame.width, height: CGFloat(move.band.count) * rowPoints)
        container.frame = band
        container.backgroundColor = geometry.surface.backgroundColor?.cgColor
        let offset = glide.offset
        current.contents = contents
        current.contentsRect = CGRect(x: 0, y: CGFloat(move.band.lowerBound) * rowPixels / CGFloat(pixels),
                                      width: 1, height: CGFloat(move.band.count) * rowPixels / CGFloat(pixels))
        current.frame = CGRect(x: 0, y: offset, width: band.width, height: band.height)
        if let gap, gap.frame.height > 0 {
            let width = CGFloat(IOSurfaceGetWidth(gap.surface)), height = CGFloat(IOSurfaceGetHeight(gap.surface))
            // The rows the band moved past, out of the edge rows kept: the last of them when it
            // moved down (they go below the band's rows), the first when it moved up (above).
            let needed = min(height, CGFloat(abs(move.rows)) * rowPixels)
            let down = move.rows > 0
            previous.contents = gap.surface
            previous.contentsRect = CGRect(x: gap.columns.minX / width, y: down ? (height - needed) / height : 0,
                                           width: gap.columns.width / width, height: needed / height)
            let gapHeight = needed * pointsPerPixel
            previous.frame = CGRect(x: gap.frame.minX - band.minX, y: down ? band.height + offset : offset - gapHeight,
                                    width: gap.frame.width, height: gapHeight)
        } else {
            previous.contents = nil
        }
        container.isHidden = false
    }

    // MARK: - Reading

    /// Keeps the frame's rows at the edges of the last move's band, for the next move's gap: the
    /// last move's size plus a row, so a steady scroll's gap is always the rows it needs.
    private func keepEdges() {
        guard let band = lastBand, let geometry = geometry(),
              let frameLayer = geometry.surface.layer.sublayers?.first(where: { $0 !== container }),
              let contents = frameLayer.contents, let pixels = Self.pixelHeight(contents), pixels > 0 else {
            edges = (nil, nil, 0)
            return
        }
        let count = min(band.count, abs(move?.rows ?? TerminalTUIRowMove.minimumMovedRows) + 1)
        let rowPoints = CGFloat(Self.rowPixels(geometry)) * frameLayer.frame.height / CGFloat(pixels)
        func rows(_ range: Range<Int>) -> TerminalPresentedCopy? {
            geometry.surface.presentedCopy(clip: CGRect(x: frameLayer.frame.minX, y: frameLayer.frame.minY + CGFloat(range.lowerBound) * rowPoints,
                                                        width: frameLayer.frame.width, height: CGFloat(range.count) * rowPoints))
        }
        edges = (rows(band.lowerBound..<band.lowerBound + count), rows(band.upperBound - count..<band.upperBound), count)
    }

    private struct Frame {
        var rows: [UInt64]
        var rowHeight: CGFloat
        /// A row's height as presented (points): its pixels over the surface's.
        var rowPoints: CGFloat
        var screenRows: Int
    }

    private func read() -> Frame? {
        guard let geometry = geometry(), geometry.rowHeight > 0, geometry.rows > 0 else { return nil }
        let rowPixels = Self.rowPixels(geometry)
        guard let rows = geometry.surface.presentedRowSignatures(rowHeight: rowPixels, band: 0..<geometry.rows) else { return nil }
        return Frame(rows: rows, rowHeight: geometry.rowHeight, rowPoints: CGFloat(rowPixels) / geometry.scale, screenRows: geometry.rows)
    }

    private static func rowPixels(_ geometry: (surface: TerminalSurfaceView, rowHeight: CGFloat, scale: CGFloat, rows: Int)) -> Int {
        Int((geometry.rowHeight * geometry.scale).rounded())
    }

    private static func pixelHeight(_ contents: Any) -> Int? {
        let ref = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        guard CFGetTypeID(ref) == IOSurfaceGetTypeID() else { return nil }
        return IOSurfaceGetHeight(ref)
    }
}
#endif
