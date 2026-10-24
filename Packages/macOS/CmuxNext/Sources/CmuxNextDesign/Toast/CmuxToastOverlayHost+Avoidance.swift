import AppKit

extension CmuxToastOverlayHost {
    /// The gap between a toast and the view it avoids.
    static let avoidanceGap: CGFloat = 8

    /// The lowest bottom edge (window coordinates) a toast of `width`,
    /// centered in `bounds`, may take in `window`: above every avoided rect
    /// under it, else `bounds.minY`.
    static func floor(width: CGFloat, in bounds: NSRect, window: NSWindow) -> CGFloat {
        let band = NSRect(x: bounds.midX - width / 2 - avoidanceGap, y: bounds.minY,
                          width: width + 2 * avoidanceGap, height: bounds.height)
        var floor = bounds.minY
        // Every shown view under the content view, a view before its subviews. An explicit stack,
        // not a recursive local function that captures `floor` (Swift 6.3.3's SendNonSendable pass
        // crashed now and then on such captures in Release).
        var pending: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = pending.popLast() {
            guard !view.isHidden, view.alphaValue > 0.01 else { continue }
            if let avoiding = view as? any CmuxToastAvoiding {
                let rect = avoiding.convert(avoiding.toastAvoidanceRect, to: nil)
                if !rect.isEmpty, rect.intersects(band) { floor = max(floor, rect.maxY + avoidanceGap) }
            }
            pending.append(contentsOf: view.subviews.reversed())
        }
        return floor
    }
}
