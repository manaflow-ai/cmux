public import AppKit
import CmuxNextDesign

/// One shown status glyph in the workspace list (`debug.sidebar_rows` "status_glyphs"), in window
/// points from the top-left: the box its mark actually draws (from the mark's mask), how soft that
/// mask is at 1x and 2x, its row title's cap-height center and the row's unread badge.
/// scripts/cmux-next/sidebar-status-glyph-live.py checks them (Leo 2026-10-13: the done and
/// working marks read tiny, blurry and low next to the badge).
public struct SidebarDebugStatusGlyph: Sendable {
    public var state: String
    public var frame: CGRect
    public var scale: CGFloat
    /// `SidebarStyle.badgeHeight`, shown or not.
    public var badgeHeight: CGFloat
    public var drawn: CGRect? = nil
    public var glyphSide: CGFloat? = nil
    /// Partly covered pixels per fully covered one: a mark drawn at its pixel size has only its
    /// outline partly covered; one resampled from another size is soft all through.
    public var soft1x: Double?
    public var soft2x: Double?
    public var title: String? = nil
    public var titleCapCenterY: CGFloat? = nil
    public var badge: CGRect? = nil
    /// What the indicator draws (`StatusIndicatorPlan.Glyph`): `arc` for the spinner, `mark` for a
    /// status icon set's mark, `dot`, `dots`, ... (cx-qtgj2: working is a spinner, not a pulse).
    public var glyph: String = ""
    /// The animation the layer runs now (`spin`, `pulse`, ...), nil when it is still (occluded,
    /// minimized, Reduce Motion or a still state).
    public var animation: String? = nil
    /// How far a spinning glyph is through its turn now (0..<1); synced spinners read the same.
    public var phase: Double? = nil
}

extension SidebarViewComponents {
    public func debugStatusGlyphs() -> [SidebarDebugStatusGlyph] {
        guard let window else { return [] }
        let height = window.contentView?.bounds.height ?? window.frame.height
        func topLeft(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: nil)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        var glyphs: [SidebarDebugStatusGlyph] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            // A pooled row's indicator is laid out at zero size until the row shows.
            guard let indicator = view as? StatusIndicatorView else { return view.subviews.forEach(walk) }
            guard indicator.showsGlyph, indicator.bounds.width > 0 else { return }
            let frame = topLeft(indicator), layer = indicator.indicator
            let scale = window.backingScaleFactor
            var glyph = SidebarDebugStatusGlyph(
                state: String(describing: indicator.state), frame: frame, scale: scale,
                badgeHeight: SidebarStyle.badgeHeight,
                soft1x: layer.debugMarkMask(scale: 1).flatMap(MaskMeasure.softness),
                soft2x: layer.debugMarkMask(scale: 2).flatMap(MaskMeasure.softness))
            if case .mark = layer.plan.glyph { glyph.glyph = "mark" } else { glyph.glyph = String(describing: layer.plan.glyph) }
            glyph.animation = layer.runningAnimation.map { String(describing: $0) }
            glyph.phase = layer.debugRotationPhase
            if let mask = layer.debugMarkMask(scale: scale), let box = MaskMeasure.alphaBox(mask) {
                // Mask rows run top to bottom; the glyph square is centered in the indicator.
                let side = CGFloat(mask.width) / scale
                glyph.drawn = CGRect(x: frame.midX - side / 2 + box.minX / scale, y: frame.midY - side / 2 + box.minY / scale,
                                     width: box.width / scale, height: box.height / scale)
                glyph.glyphSide = layer.debugGlyphRect.width
            }
            if let row = sequence(first: indicator.superview, next: { $0?.superview }).lazy.compactMap({ $0 as? WorkspaceRowView }).first {
                // The title is top-aligned: its baseline sits the font's ascender below its top.
                if !row.title.isHidden {
                    glyph.title = row.title.stringValue
                    glyph.titleCapCenterY = topLeft(row.title).minY + row.title.font.ascender - row.title.font.capHeight / 2
                }
                glyph.badge = row.subviews.first { $0 is UnreadBadgeView && !$0.isHidden }.map(topLeft)
            }
            glyphs.append(glyph)
        }
        walk(self)
        return glyphs
    }
}

private enum MaskMeasure {
    static func softness(_ mask: CGImage) -> Double? {
        guard let alpha = alphaBytes(mask) else { return nil }
        let partial = alpha.filter { $0 > 12 && $0 < 243 }.count
        let solid = alpha.filter { $0 >= 243 }.count
        return (Double(partial) / Double(max(1, solid)) * 100).rounded() / 100
    }

    /// The box of pixels at least half covered, in mask pixels (rows top to bottom).
    static func alphaBox(_ mask: CGImage) -> CGRect? {
        guard let alpha = alphaBytes(mask) else { return nil }
        let width = mask.width
        var minX = width, minY = mask.height, maxX = -1, maxY = -1
        for (index, value) in alpha.enumerated() where value > 127 {
            let x = index % width, y = index / width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func alphaBytes(_ mask: CGImage) -> [UInt8]? {
        let width = mask.width, height = mask.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
            else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
