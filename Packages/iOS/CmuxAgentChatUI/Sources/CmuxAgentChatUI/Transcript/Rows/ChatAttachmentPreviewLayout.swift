import CoreGraphics

/// Stable inline-image geometry derived only from transcript metadata.
///
/// Loading a thumbnail never changes the reserved footprint. Missing or
/// invalid dimensions use a deterministic 4:3 fallback. Extreme aspect ratios
/// keep their source ratio and shrink one dimension to stay bounded.
struct ChatAttachmentPreviewLayout: Equatable, Sendable {
    private static let fallbackAspectRatio: CGFloat = 4 / 3
    private static let maximumHeightToWidthRatio: CGFloat = 1.25

    let aspectRatio: CGFloat

    init(pixelWidth: Int?, pixelHeight: Int?, aspectRatio providedAspectRatio: Double? = nil) {
        if let pixelWidth,
           let pixelHeight,
           pixelWidth > 0,
           pixelHeight > 0 {
            aspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        } else if let providedAspectRatio,
                  providedAspectRatio.isFinite,
                  providedAspectRatio > 0 {
            aspectRatio = CGFloat(providedAspectRatio)
        } else {
            aspectRatio = Self.fallbackAspectRatio
        }
    }

    func size(maxWidth: CGFloat) -> CGSize {
        guard maxWidth.isFinite, maxWidth > 0 else { return .zero }
        let idealHeight = maxWidth / aspectRatio
        let maximumHeight = maxWidth * Self.maximumHeightToWidthRatio
        if idealHeight <= maximumHeight {
            return CGSize(width: maxWidth, height: idealHeight)
        }
        return CGSize(width: maximumHeight * aspectRatio, height: maximumHeight)
    }
}
