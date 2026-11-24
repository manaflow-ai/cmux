public import CoreGraphics

/// An agent running in a terminal draws its mark the way a terminal draws a selected cell, in reverse video:
/// a rounded square in the row's ink, the mark cut out of it to true transparency, so whatever lies under the
/// slot (the row, its hover or selection fill) shows through the mark. Leo 2026-11-24 (ask-97938b6c84): "terminal
/// agent chats. can they be demarcated a bit differently/should they? than gui agent chats." The geometry is the
/// web `TerminalChatMark`'s (`terminalTileRadius`, `terminalTileMarkSize`), so every surface draws one tile.
public struct TerminalMarkTile {
    public init() {}
    /// The smallest slot that holds a tile. Below it the mark inside would leave the 12/16/20 icon scale,
    /// so a 12 pt slot keeps the bare mark.
    public static let minimumSlot: CGFloat = 16

    /// Whether a `slot`-point square draws the tile rather than the bare mark.
    public static func holds(slot: CGFloat) -> Bool { slot >= minimumSlot }

    /// The mark's side on a tile of `slot`: the largest icon-scale size that leaves 2 pt of tile on each side
    /// (12 on a 16 tile, 20 on iPhone's 32), else the tile less 4.
    public static func markSide(slot: CGFloat) -> CGFloat {
        [20, 16, 12].first { $0 <= slot - 4 } ?? max(0, slot - 4)
    }

    /// The tile's corner: the design scale's control corner, min(8, floor4(slot / 3)): 4 on a 16 tile, 8 on a 32.
    public static func cornerRadius(slot: CGFloat) -> CGFloat {
        min(8, max(2, (slot / 3 / 4).rounded(.down) * 4))
    }

    /// The tile for `mark`, a square image of the mark at ``markSide(slot:)`` (its colour does not count, only its
    /// alpha): a `slot`-point square at `scale` pixels per point, filled `ink` with rounded corners, the mark
    /// knocked out of its centre (destination-out), placed on whole pixels. Nil for a slot with no pixels.
    public static func image(mark: CGImage, slot: CGFloat, scale: CGFloat, ink: CGColor) -> CGImage? {
        let pixels = Int((slot * scale).rounded())
        let markPixels = Int((markSide(slot: slot) * scale).rounded())
        guard pixels > 0, markPixels > 0, let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let radius = cornerRadius(slot: slot) * scale
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: pixels, height: pixels),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(ink)
        context.fillPath()
        let inset = CGFloat((pixels - markPixels) / 2)
        context.setBlendMode(.destinationOut)
        context.draw(mark, in: CGRect(x: inset, y: inset, width: CGFloat(markPixels), height: CGFloat(markPixels)))
        return context.makeImage()
    }
}
