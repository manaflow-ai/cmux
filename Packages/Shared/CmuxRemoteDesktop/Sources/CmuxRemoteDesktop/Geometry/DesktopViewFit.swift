/// The view math both ends agree on (c3-rd.md 4): fit a target rect into
/// the phone's pixels without upscaling and under the long-edge cap, and
/// clamp a requested view to the target.
public struct DesktopViewFit: Hashable, Sendable {
    /// Largest target side either end accepts (16K displays fit).
    public static let maxTargetSide = 16_384

    /// Longest encoded edge (VideoToolbox real time stays cheap below it).
    public var maxLongEdge: Int
    /// Smallest rect side a view may crop to, in target pixels.
    public var minRectSide: Int

    public init(maxLongEdge: Int = 2560, minRectSide: Int = 64) {
        self.maxLongEdge = max(16, maxLongEdge)
        self.minRectSide = max(2, minRectSide)
    }

    /// Encode pixels for `rect` shown in at most `maxWidth x maxHeight`:
    /// aspect kept, never above the rect's own pixels or the long-edge cap,
    /// even, at least 2.
    public func pixelSize(for rect: DesktopRect, maxWidth: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard rect.width > 0, rect.height > 0 else { return (2, 2) }
        let w = Double(rect.width)
        let h = Double(rect.height)
        var scale = min(Double(max(2, maxWidth)) / w, Double(max(2, maxHeight)) / h, 1)
        scale = min(scale, Double(maxLongEdge) / max(w, h))
        return (Self.even(w * scale), Self.even(h * scale))
    }

    /// The first view: the whole target fit into the phone screen.
    public func initialView(target: DesktopTargetInfo, screen: DesktopScreen) -> DesktopView {
        let rect = target.bounds
        let size = pixelSize(for: rect, maxWidth: screen.pixelWidth, maxHeight: screen.pixelHeight)
        return DesktopView(seq: 0, rect: rect, pixelWidth: size.width, pixelHeight: size.height)
    }

    /// `requested` clamped to the target: the rect moved inside the bounds
    /// (shrunk to them when larger), at least `minRectSide` per side, and its
    /// pixel size refit. The seq is kept.
    public func clamp(_ requested: DesktopView, to target: DesktopTargetInfo) -> DesktopView {
        let bounds = target.bounds
        guard !bounds.isEmpty else { return DesktopView(seq: requested.seq, rect: bounds, pixelWidth: 2, pixelHeight: 2) }
        let width = min(max(requested.rect.width, min(minRectSide, bounds.width)), bounds.width)
        let height = min(max(requested.rect.height, min(minRectSide, bounds.height)), bounds.height)
        let x = min(max(requested.rect.x, 0), bounds.width - width)
        let y = min(max(requested.rect.y, 0), bounds.height - height)
        let rect = DesktopRect(x: x, y: y, width: width, height: height)
        let size = pixelSize(for: rect, maxWidth: max(2, requested.pixelWidth), maxHeight: max(2, requested.pixelHeight))
        return DesktopView(seq: requested.seq, rect: rect, pixelWidth: size.width, pixelHeight: size.height)
    }

    private static func even(_ value: Double) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}
