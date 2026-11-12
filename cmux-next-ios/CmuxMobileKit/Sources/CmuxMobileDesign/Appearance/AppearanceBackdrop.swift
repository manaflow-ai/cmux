#if os(iOS)
import CoreImage
import ImageIO
import SwiftUI
import UIKit

/// The page under the chrome: `bg` alone, or, with a Mac background, the
/// theme's opaque background, the image (cropped to fill this view, centred,
/// blurred and faded on the phone) and the theme's tint over it. Glass draws
/// over it as it draws over any page: translucency is intended, so the
/// backdrop never makes a glass control opaque.
public struct CmuxMobileBackdrop: View {
    private let appearance = CmuxMobileAppearance.shared
    @Environment(\.displayScale) private var scale

    public init() {}

    public var body: some View {
        if let style = appearance.backdrop {
            GeometryReader { proxy in
                BackdropImage(style: style, size: proxy.size, scale: scale)
            }
        } else {
            CmuxMobileTheme.standard.colors.bg.color
        }
    }
}

private struct BackdropImage: View {
    let style: CmuxMobileBackdropStyle
    let size: CGSize
    let scale: CGFloat
    @State private var image: UIImage?

    private var key: CmuxMobileBackdropImages.Key {
        .init(sha256: style.sha256, url: style.imageURL, pixelWidth: Int((size.width * scale).rounded()),
              pixelHeight: Int((size.height * scale).rounded()), blur: style.blur * scale)
    }

    var body: some View {
        ZStack {
            style.base.color
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .opacity(style.opacity)
                    .transition(.opacity)
            }
            style.tint.color
        }
        .frame(width: size.width, height: size.height)
        .task(id: key) {
            if let cached = CmuxMobileBackdropImages.cached(key) {
                image = cached
                return
            }
            let made = await CmuxMobileBackdropImages.image(key)
            withAnimation(.easeOut(duration: 0.2)) { image = made }
        }
    }
}

/// The same backdrop for a UIKit container (the sidebar's sliding card). It
/// follows the appearance through the window's revision trait.
public final class CmuxMobileBackdropUIView: UIView {
    private let imageView = UIImageView()
    private let tintView = UIView()
    private var loading: Task<Void, Never>?
    private var shownKey: CmuxMobileBackdropImages.Key?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        addSubview(tintView)
        registerForTraitChanges([CmuxMobileAppearanceRevisionTrait.self, UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.refresh()
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        tintView.frame = bounds
        refresh()
    }

    private func refresh() {
        let appearance = CmuxMobileAppearance.shared
        guard let style = appearance.backdrop else {
            backgroundColor = CmuxMobileColorRole.bg.uiColor
            imageView.image = nil
            tintView.backgroundColor = .clear
            shownKey = nil
            return
        }
        backgroundColor = style.base.uiColor
        tintView.backgroundColor = style.tint.uiColor
        imageView.alpha = style.opacity
        let scale = traitCollection.displayScale
        guard bounds.width > 0, bounds.height > 0 else { return }
        let key = CmuxMobileBackdropImages.Key(sha256: style.sha256, url: style.imageURL, pixelWidth: Int((bounds.width * scale).rounded()),
                                               pixelHeight: Int((bounds.height * scale).rounded()), blur: style.blur * scale)
        guard key != shownKey else { return }
        shownKey = key
        if let cached = CmuxMobileBackdropImages.cached(key) {
            imageView.image = cached
            return
        }
        loading?.cancel()
        loading = Task { @MainActor [weak self] in
            let made = await CmuxMobileBackdropImages.image(key)
            guard let self, !Task.isCancelled, self.shownKey == key else { return }
            UIView.transition(with: self.imageView, duration: 0.2, options: .transitionCrossDissolve) { self.imageView.image = made }
        }
    }
}

/// The backdrop bitmaps: one per (image, pixel size, blur), made off the main
/// thread at the screen's own pixel size (never the full-size image) and
/// shared by every screen that draws it.
public enum CmuxMobileBackdropImages {
    public struct Key: Hashable, Sendable {
        public var sha256: String
        public var url: URL
        public var pixelWidth: Int
        public var pixelHeight: Int
        public var blur: Double
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var images: [Key: UIImage] = [:]
        var order: [Key] = []
    }

    private static let box = Box()

    /// A bitmap handed back from the render thread (made there, then only read).
    private struct Made: @unchecked Sendable { let image: UIImage? }
    /// Bitmaps kept: a few sizes (portrait, landscape, the sidebar card) of one image.
    static let limit = 4

    public static func cached(_ key: Key) -> UIImage? {
        box.lock.withLock { box.images[key] }
    }

    /// The bitmap for `key`, made on a background thread when not cached.
    public static func image(_ key: Key) async -> UIImage? {
        if let cached = cached(key) { return cached }
        let made = await Task.detached(priority: .userInitiated) { Made(image: render(key)) }.value.image
        guard let made else { return nil }
        box.lock.withLock {
            box.images[key] = made
            box.order.removeAll { $0 == key }
            box.order.append(key)
            while box.order.count > limit { box.images[box.order.removeFirst()] = nil }
        }
        return made
    }

    /// Decodes the image downsampled so it just covers `pixelWidth` x
    /// `pixelHeight` (ImageIO thumbnail: the full-size bitmap is never made),
    /// crops it centred to that size and blurs it (edges clamped, so no
    /// translucent rim).
    static func render(_ key: Key) -> UIImage? {
        guard key.pixelWidth > 0, key.pixelHeight > 0,
              let source = CGImageSourceCreateWithURL(key.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let fill = max(Double(key.pixelWidth) / Double(width), Double(key.pixelHeight) / Double(height))
        let longSide = Int((Double(max(width, height)) * fill).rounded(.up))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longSide, max(width, height)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Aspect fill, centred: the crop of the thumbnail with the target's aspect.
        let target = Double(key.pixelWidth) / Double(key.pixelHeight)
        let tw = Double(thumb.width), th = Double(thumb.height)
        let crop: CGRect = tw / th > target
            ? CGRect(x: ((tw - th * target) / 2).rounded(), y: 0, width: (th * target).rounded(), height: th)
            : CGRect(x: 0, y: ((th - tw / target) / 2).rounded(), width: tw, height: (tw / target).rounded())
        guard let cropped = thumb.cropping(to: crop) else { return nil }
        guard key.blur > 0.5 else { return UIImage(cgImage: cropped) }
        let input = CIImage(cgImage: cropped)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: key.blur / 2).cropped(to: input.extent)
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let out = context.createCGImage(blurred, from: input.extent) else { return UIImage(cgImage: cropped) }
        return UIImage(cgImage: out)
    }
}
#endif
