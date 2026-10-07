#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Whether a view sits over a conversation background. The transcript sets
/// it (with a user interface style derived from the background's luminance,
/// as ChatKit's `contentDerivedUserInterfaceStyleForLuminance` does) and
/// views that draw over the background read it: incoming bubbles turn into
/// material, the top wash takes the background's color.
struct ConversationBackdropTrait: UITraitDefinition {
    static let defaultValue = false
    static let affectsColorAppearance = true
    static let name = "ConversationBackdrop"
}

extension UITraitCollection {
    var isOverConversationBackdrop: Bool { self[ConversationBackdropTrait.self] }
}

extension UIMutableTraits {
    var isOverConversationBackdrop: Bool {
        get { self[ConversationBackdropTrait.self] }
        set { self[ConversationBackdropTrait.self] = newValue }
    }
}

/// The background behind the transcript: a `ConversationBackdropLayer`
/// following Reduce Motion and Increase Contrast, plus the photo's loading.
final class ConversationBackdropView: UIView {
    override class var layerClass: AnyClass { ConversationBackdropLayer.self }
    var backdrop: ConversationBackdropLayer { layer as! ConversationBackdropLayer }

    private(set) var background: ConversationBackground?
    private var photoTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "conversation.background"
        backdrop.isMotionPaused = UIAccessibility.isReduceMotionEnabled
        backdrop.increasesContrast = traitCollection.accessibilityContrast == .high
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitAccessibilityContrast.self]) { (self: Self, _: UITraitCollection) in
            self.backdrop.increasesContrast = self.traitCollection.accessibilityContrast == .high
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reduceMotionChanged() {
        backdrop.isMotionPaused = UIAccessibility.isReduceMotionEnabled
    }

    /// Shows `background`; a photo appears once decoded (its luminance gray until then).
    func show(_ background: ConversationBackground?, animated: Bool) {
        let previous = self.background
        self.background = background
        guard let background, background.kind == .photo, let photo = background.photo else {
            photoTask?.cancel()
            photoTask = nil
            backdrop.set(background, image: nil, animated: animated && previous?.id != background?.id)
            return
        }
        // The same photo (a confirmation of mine): keep what is on screen.
        if previous?.kind == .photo, previous?.photo?.url == photo.url || (photo.localData != nil && previous?.photo?.localData == photo.localData),
           let image = backdrop.image {
            backdrop.set(background, image: image, animated: false)
            return
        }
        backdrop.set(background, image: nil, animated: animated)
        let attachment = ConversationAttachment(
            id: "background:\(photo.url?.absoluteString ?? background.id)",
            kind: .image,
            width: photo.width,
            height: photo.height,
            url: photo.url,
            localData: photo.localData
        )
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let aspect = photo.height > 0 ? CGFloat(photo.width) / CGFloat(photo.height) : 1
        let pixelWidth = max(bounds.width, bounds.height * aspect, 400) * max(scale, 1)
        photoTask?.cancel()
        photoTask = Task { [weak self] in
            let image = await ConversationImageLoader.shared.image(for: attachment, pixelWidth: pixelWidth)
            guard let self, !Task.isCancelled, self.background?.id == background.id, let cgImage = image?.cgImage else { return }
            self.backdrop.set(background, image: cgImage, animated: true)
        }
    }

    /// The color the transcript's top wash fades to over this background.
    var washColor: UIColor? {
        guard let background else { return nil }
        if background.kind == .photo { return nil }
        return background.colors.first.flatMap(ConversationBackdropLayer.cgColor(hex:)).map(UIColor.init(cgColor:))
    }
}
#endif
