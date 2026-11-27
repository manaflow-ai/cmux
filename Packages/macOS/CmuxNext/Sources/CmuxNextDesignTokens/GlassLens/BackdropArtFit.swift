public import CoreGraphics

/// How the art fills its view, as macOS draws a desktop picture (System Settings > Wallpaper's
/// menu): the Desktop Wallpaper background follows the screen's own choice, every other
/// background fills. The art layer, the video and the glass lens rect (``GlassBackdropRect``)
/// all place the picture by it, so the page lenses what the window draws.
///
/// ```swift
/// let fit = BackdropArtFit(imageScaling: 3, allowClipping: false)   // .fit
/// let rect = fit.rect(of: CGSize(width: 16, height: 9), in: bounds, pointsPerPixel: 0.5)
/// ```
public nonisolated enum BackdropArtFit: String, Hashable, Sendable {
    /// Aspect-filled and centered: the picture covers the view and overhangs it (Fill Screen).
    case fill
    /// Aspect-fitted and centered: the fill color letterboxes it (Fit to Screen).
    case fit
    /// Resized to the view, aspect lost (Stretch to Fill Screen).
    case stretch
    /// At its own size, centered: the fill color around it (Center).
    case center

    /// The fit macOS's desktop options name (`NSWorkspace.DesktopImageOptionKey`).
    ///
    /// macOS writes Fill Screen as proportional scaling that clips, Fit to Screen as proportional
    /// scaling that does not, Stretch as independent axes and Center as no scaling. Tile has no
    /// value of its own in these options (macOS reports it as one of the others), so it shows as
    /// what macOS reports. Shrink-only scaling (`scaleProportionallyDown`, which System Settings
    /// never writes) fits. No options at all is macOS's own default, Fill Screen.
    /// - Parameters:
    ///   - imageScaling: `NSImageScaling`'s raw value (0 down, 1 axes, 2 none, 3 up or down).
    ///   - allowClipping: Whether the picture may be cropped to fill the screen.
    public init(imageScaling: Int?, allowClipping: Bool?) {
        switch imageScaling {
        case 1: self = .stretch
        case 2: self = .center
        case 0: self = .fit
        case 3: self = allowClipping == false ? .fit : .fill
        default: self = .fill
        }
    }

    /// Whether the fill color shows around the picture (letterbox or border).
    public var showsFill: Bool { self == .fit || self == .center }

    /// Where an `imageSize` picture lies in `bounds`; nil when either has no area.
    /// - Parameters:
    ///   - imageSize: The decoded picture's size in pixels (only its aspect matters, but for ``center``).
    ///   - bounds: The view the picture is drawn in.
    ///   - pointsPerPixel: Points per picture pixel (1 / the screen's backing scale), for ``center``.
    public func rect(of imageSize: CGSize, in bounds: CGRect, pointsPerPixel: CGFloat = 1) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let size: CGSize
        switch self {
        case .stretch:
            return bounds
        case .fill, .fit:
            let widthScale = bounds.width / imageSize.width, heightScale = bounds.height / imageSize.height
            let scale = self == .fill ? max(widthScale, heightScale) : min(widthScale, heightScale)
            size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        case .center:
            let scale = pointsPerPixel > 0 && pointsPerPixel.isFinite ? pointsPerPixel : 1
            size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
}
