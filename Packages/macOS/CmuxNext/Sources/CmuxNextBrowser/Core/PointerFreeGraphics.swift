import CoreGraphics

nonisolated extension CGContext {
    /// An 8-bit-per-component bitmap context whose pixels Core Graphics allocates, owns and frees
    /// with the context. Callers draw into it and read it back only through `makeImage()`, so no
    /// Swift pointer to the pixels exists. Nil when Core Graphics refuses the size or format.
    static func ownedBitmap(width: Int, height: Int, space: CGColorSpace, bitmapInfo: UInt32) -> CGContext? {
        // SAFETY: `data` is nil, so Core Graphics allocates a buffer sized from width, height and
        // the row bytes it picks (bytesPerRow 0), and frees it with the context; nothing is read or
        // written through a pointer passed from here.
        unsafe CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: bitmapInfo)
    }
}

nonisolated extension CGPath {
    /// `rect` with `radius` corners, built through the Core Graphics overlay's `addRoundedRect`:
    /// the path `CGPath(roundedRect:cornerWidth:cornerHeight:transform:)` makes, without its
    /// transform pointer.
    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        return path
    }
}
