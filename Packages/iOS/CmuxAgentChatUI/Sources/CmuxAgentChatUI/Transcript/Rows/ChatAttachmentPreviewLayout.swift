import CoreGraphics

/// Stable inline-image geometry derived only from transcript metadata.
///
/// Loading a thumbnail never changes the reserved footprint. Missing or
/// invalid dimensions use a deterministic 4:3 fallback, while extreme aspect
/// ratios are clamped to keep screenshots useful inside a transcript row.
struct ChatAttachmentPreviewLayout: Equatable, Sendable {
    private static let fallbackAspectRatio: CGFloat = 4 / 3
    private static let minimumAspectRatio: CGFloat = 0.8
    private static let maximumAspectRatio: CGFloat = 2

    let aspectRatio: CGFloat

    init(pixelWidth: Int?, pixelHeight: Int?) {
        if let pixelWidth,
           let pixelHeight,
           pixelWidth > 0,
           pixelHeight > 0 {
            let sourceAspectRatio = CGFloat(pixelWidth) / CGFloat(pixelHeight)
            aspectRatio = min(
                Self.maximumAspectRatio,
                max(Self.minimumAspectRatio, sourceAspectRatio)
            )
        } else {
            aspectRatio = Self.fallbackAspectRatio
        }
    }

    func size(maxWidth: CGFloat) -> CGSize {
        guard maxWidth.isFinite, maxWidth > 0 else { return .zero }
        return CGSize(width: maxWidth, height: maxWidth / aspectRatio)
    }
}
