import AppKit

/// `Image(src)`: a file inside the app bundle (never the network), scaled to fit the width it gets
/// (its `frame` usually sets it), as high as its aspect ratio makes it. A path outside the bundle,
/// or a file that does not decode, draws nothing.
final class AppSceneImageNSView: AppSceneNodeNSView {
    private let imageView = NSImageView()

    override init(id: String, node: AppSceneNode) {
        super.init(id: id, node: node)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)
    }

    override func configure(_ node: AppSceneNode) {
        super.configure(node)
        imageView.image = AppBundleImageCache.shared.image(path: node.string("src"), in: bundleDirectory)
        setAccessibilityElement(imageView.image != nil)
        setAccessibilityRole(.image)
        setAccessibilityLabel(node.string("help"))
    }

    override func contentHeight(width: CGFloat) -> CGFloat {
        guard let size = imageView.image?.size, size.width > 0 else { return 0 }
        return ceil(width * size.height / size.width)
    }

    override func layoutContent(in rect: CGRect) { imageView.frame = rect }
}
