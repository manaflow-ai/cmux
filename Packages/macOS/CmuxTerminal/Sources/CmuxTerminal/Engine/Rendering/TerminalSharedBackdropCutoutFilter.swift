public import CoreImage

/// Core Image filter that cuts a pane-local terminal fill out of the shared
/// window backdrop.
///
/// Lifted verbatim from `Sources/GhosttyTerminalView.swift`. AppKit drives this
/// as a view `compositingFilter`: it supplies the cutout mask as the input
/// image and the already-rendered shared backdrop as the background image, and
/// the filter subtracts the mask from the backdrop with a destination-out
/// blend so the pane-local fill shows through.
public final class TerminalSharedBackdropCutoutFilter: CIFilter {
    private static let filterInputKeys = [kCIInputImageKey, kCIInputBackgroundImageKey]
    private static let filterOutputKeys = [kCIOutputImageKey]

    /// The mask image supplied by AppKit for the cutout view.
    @objc dynamic var inputImage: CIImage?

    /// The already-rendered shared backdrop behind the terminal surface.
    @objc dynamic var inputBackgroundImage: CIImage?

    /// Creates an unconfigured cutout filter.
    public override init() {
        super.init()
    }

    /// Decodes an unconfigured cutout filter (AppKit may archive view filters).
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Input keys advertised to AppKit's Core Image compositing pipeline.
    public override var inputKeys: [String] {
        Self.filterInputKeys
    }

    /// Output keys advertised to AppKit's Core Image compositing pipeline.
    public override var outputKeys: [String] {
        Self.filterOutputKeys
    }

    /// The backdrop image with the cutout mask removed.
    public override var outputImage: CIImage? {
        guard let inputImage, let inputBackgroundImage else { return nil }
        return CIBlendKernel.destinationOut.apply(
            foreground: inputImage,
            background: inputBackgroundImage
        )
    }
}
