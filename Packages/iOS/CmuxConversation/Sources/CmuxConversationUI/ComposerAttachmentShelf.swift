#if canImport(UIKit)
import CmuxConversationGeometry
import CoreImage
import UIKit

/// Messages' queued-photo shelf at the top of the composer field: a
/// horizontally scrolling strip of 155 pt previews above a 1 pt divider.
///
/// Appends scroll the strip to its end, then fade the new preview in; a
/// removed preview blurs, shrinks and fades while the others close the gap,
/// all on Messages' critically damped shelf spring
/// (`ComposerAttachmentShelfMotion`).
final class ComposerAttachmentShelf: UIView {
    typealias Geometry = ComposerAttachmentShelfGeometry
    typealias Motion = ComposerAttachmentShelfMotion

    /// A preview's remove button was tapped.
    var onRemove: ((UUID) -> Void)?

    let strip = UIScrollView()
    let divider = UIView()
    private var items: [Item] = []

    @MainActor private final class Item {
        let id: UUID
        let aspectRatio: CGFloat
        let view = UIView()
        let imageView: UIImageView
        let removeButton = UIButton(type: .custom)

        init(id: UUID, image: UIImage) {
            self.id = id
            aspectRatio = image.size.width / max(image.size.height, 1)
            imageView = UIImageView(image: image)
        }
    }

    /// Light: black at 12 % (222 on 254); dark: white at 13 % (63 on 33).
    static let dividerColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.13) : UIColor(white: 0, alpha: 0.12)
    }

    /// The remove disc: an opaque neutral gray, 83 in light and 97 in dark.
    static let removeDiscColor = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 97 / 255, green: 97 / 255, blue: 98 / 255, alpha: 1)
            : UIColor(red: 83 / 255, green: 83 / 255, blue: 84 / 255, alpha: 1)
    }

    private var previewCornerRadius: CGFloat { Geometry.previewCornerRadius }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        strip.showsHorizontalScrollIndicator = false
        strip.alwaysBounceHorizontal = true
        strip.clipsToBounds = false
        addSubview(strip)
        divider.backgroundColor = Self.dividerColor
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { items.isEmpty }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The strip hangs from the shelf's top: while the field grows for
        // the first photo, the previews are revealed top first.
        strip.frame = CGRect(x: 0, y: Geometry.inset, width: bounds.width, height: Geometry.previewHeight)
        divider.frame = CGRect(
            x: Geometry.dividerSideInset, y: bounds.height - Geometry.dividerHeight,
            width: max(0, bounds.width - 2 * Geometry.dividerSideInset), height: Geometry.dividerHeight
        )
        if strip.bounds.width > 0, strip.contentSize.width == 0 || layoutWidth != strip.bounds.width {
            layoutWidth = strip.bounds.width
            UIView.performWithoutAnimation { applyLayout() }
        }
    }

    private var layoutWidth: CGFloat = 0

    private var frames: [CGRect] {
        Geometry.previewFrames(aspectRatios: items.map(\.aspectRatio), shelfWidth: strip.bounds.width)
    }

    /// Places every preview at its slot and sizes the strip's content.
    private func applyLayout() {
        let frames = self.frames
        for (item, frame) in zip(items, frames) { place(item, frame) }
        strip.contentSize = CGSize(width: Geometry.contentWidth(frames: frames), height: Geometry.previewHeight)
    }

    private func place(_ item: Item, _ frame: CGRect) {
        item.view.bounds = CGRect(origin: .zero, size: frame.size)
        item.view.center = CGPoint(x: frame.midX, y: frame.midY)
        item.imageView.frame = item.view.bounds
        let hit: CGFloat = 32
        item.removeButton.frame = CGRect(
            x: frame.width - Geometry.removeCenterInsetFromRight - hit / 2,
            y: Geometry.removeCenterInsetFromTop - hit / 2, width: hit, height: hit
        )
    }

    // MARK: Changes

    /// Adds a preview. With `animated`, the strip scrolls to its end on the
    /// shelf spring and the new preview fades in a beat later; the first
    /// preview of an empty shelf appears at once (the field's growth reveals it).
    func append(id: UUID, image: UIImage, animated: Bool) {
        let item = makeItem(id: id, image: image)
        let wasEmpty = items.isEmpty
        items.append(item)
        strip.addSubview(item.view)
        guard strip.bounds.width > 0 else { return }
        let frames = self.frames
        let contentWidth = Geometry.contentWidth(frames: frames)
        let endOffset = Geometry.endOffset(contentWidth: contentWidth, shelfWidth: strip.bounds.width)
        UIView.performWithoutAnimation {
            place(item, frames[frames.count - 1])
            strip.contentSize = CGSize(width: contentWidth, height: Geometry.previewHeight)
        }
        guard animated, !wasEmpty else {
            strip.contentOffset = CGPoint(x: endOffset, y: 0)
            if animated { flashClearButton() }
            return
        }
        item.view.alpha = 0
        Self.animate {
            self.strip.contentOffset = CGPoint(x: endOffset, y: 0)
        }
        Self.animate(delay: Motion.secondPhaseDelay) {
            item.view.alpha = 1
        }
    }

    /// Removes a preview. With `animated` and others left, the removed one
    /// blurs, shrinks and fades (from the first slot when it was the last of
    /// several) while the rest slide to close the gap a beat later. The last
    /// preview leaves at once: the field collapses around it.
    func remove(id: UUID, animated: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldFrames = frames
        let item = items.remove(at: index)
        guard animated, !items.isEmpty, strip.bounds.width > 0 else {
            item.view.removeFromSuperview()
            UIView.performWithoutAnimation { applyLayout() }
            if items.isEmpty { strip.contentOffset = .zero }
            return
        }
        playExit(item, from: Geometry.exitFrame(removedIndex: index, frames: oldFrames))
        let frames = self.frames
        let contentWidth = Geometry.contentWidth(frames: frames)
        let offset = Geometry.clampedOffset(strip.contentOffset.x, contentWidth: contentWidth, shelfWidth: strip.bounds.width)
        // The content size shrinks with the slide; keep the current offset
        // reachable until the slide has carried it to its clamped value.
        strip.contentSize.width = max(strip.contentSize.width, contentWidth)
        Self.animate(delay: Motion.removalDelay + Motion.secondPhaseDelay) {
            for (item, frame) in zip(self.items, frames) { self.place(item, frame) }
            self.strip.contentOffset = CGPoint(x: offset, y: 0)
        } completion: { [weak self] in
            guard let self else { return }
            self.strip.contentSize = CGSize(width: Geometry.contentWidth(frames: self.frames), height: Geometry.previewHeight)
        }
    }

    /// Drops every preview at once (after a send, or the last one removed).
    func removeAll() {
        items.forEach { $0.view.removeFromSuperview() }
        items = []
        strip.contentSize = .zero
        strip.contentOffset = .zero
    }

    /// Light 156 gray, dark 68 gray: the disc of the clear button Messages
    /// flashes when the shelf opens.
    static let clearFlashColor = UIColor { traits in
        UIColor(white: traits.userInterfaceStyle == .dark ? 68 / 255 : 156 / 255, alpha: 1)
    }

    /// Messages' shelf opens with its clear button showing and fades it out
    /// as the field grows (iOS 26.5 and 27.0).
    private func flashClearButton() {
        let diameter = Geometry.removeDiscDiameter
        let disc = UIView(frame: CGRect(
            x: bounds.width - Geometry.clearFlashCenterInsetFromRight - diameter / 2,
            y: Geometry.clearFlashCenterInsetFromTop - diameter / 2, width: diameter, height: diameter
        ))
        disc.autoresizingMask = [.flexibleLeftMargin]
        disc.isUserInteractionEnabled = false
        disc.backgroundColor = Self.clearFlashColor
        disc.layer.cornerRadius = diameter / 2
        let cross = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
        cross.tintColor = .white
        cross.contentMode = .center
        cross.frame = disc.bounds
        disc.addSubview(cross)
        addSubview(disc)
        Self.animate {
            disc.alpha = 0
        } completion: {
            disc.removeFromSuperview()
        }
    }

    // MARK: Exit

    private func playExit(_ item: Item, from frame: CGRect) {
        item.removeButton.isHidden = true
        let exit = UIView()
        exit.isUserInteractionEnabled = false
        let sharp = item.view
        let current = sharp.frame
        UIView.performWithoutAnimation {
            exit.bounds = CGRect(origin: .zero, size: current.size)
            exit.center = CGPoint(x: current.midX, y: current.midY)
            sharp.center = CGPoint(x: exit.bounds.midX, y: exit.bounds.midY)
            exit.addSubview(sharp)
            // The removed preview passes over its neighbors.
            strip.addSubview(exit)
        }
        let blurred = UIImageView(image: Self.blurredPreview(item.imageView.image, size: frame.size, cornerRadius: previewCornerRadius))
        let pad = Motion.exitBlurRadius * 2
        blurred.frame = exit.bounds.insetBy(dx: -pad, dy: -pad)
        blurred.alpha = 0
        exit.insertSubview(blurred, belowSubview: sharp)
        let delay = Motion.removalDelay
        if frame.origin != current.origin {
            // The last of several jumps to the first slot as its exit starts.
            UIView.animate(withDuration: 0.001, delay: delay, options: []) {
                exit.center = CGPoint(x: frame.midX, y: frame.midY)
            }
        }
        // Under the fading sharp photo, the blurred one comes up at once, so
        // the preview stays opaque while it blurs; the whole fades on the spring.
        UIView.animate(withDuration: Motion.exitBlurRamp, delay: delay, options: [.curveLinear]) {
            blurred.alpha = 1
        }
        Self.animate(delay: delay) {
            exit.transform = CGAffineTransform(scaleX: Motion.exitScale, y: Motion.exitScale)
            exit.alpha = 0
            sharp.alpha = 0
        } completion: {
            exit.removeFromSuperview()
        }
    }

    /// The preview's photo, clipped to its corners and blurred, on a
    /// transparent margin so the blur spreads past its edge.
    private static func blurredPreview(_ image: UIImage?, size: CGSize, cornerRadius: CGFloat) -> UIImage? {
        guard let image, size.width > 0, size.height > 0 else { return nil }
        let pad = Motion.exitBlurRadius * 2
        let canvas = CGRect(x: 0, y: 0, width: size.width + 2 * pad, height: size.height + 2 * pad)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sharp = UIGraphicsImageRenderer(bounds: canvas, format: format).image { _ in
            let box = CGRect(x: pad, y: pad, width: size.width, height: size.height)
            UIBezierPath(roundedRect: box, cornerRadius: cornerRadius).addClip()
            let fill = max(box.width / image.size.width, box.height / image.size.height)
            let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
            image.draw(in: CGRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
        }
        guard let input = CIImage(image: sharp), let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(Motion.exitBlurRadius / 2, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .up)
    }

    // MARK: Items

    private func makeItem(id: UUID, image: UIImage) -> Item {
        let item = Item(id: id, image: image)
        item.imageView.contentMode = .scaleAspectFill
        item.imageView.clipsToBounds = true
        styleCorners(item)
        item.view.addSubview(item.imageView)
        // An 18 pt opaque gray disc with a white cross (Messages' "Cancel
        // Button"), inside a 32 pt hit target.
        let diameter = Geometry.removeDiscDiameter
        let disc = UIView(frame: CGRect(x: (32 - diameter) / 2, y: (32 - diameter) / 2, width: diameter, height: diameter))
        disc.backgroundColor = Self.removeDiscColor
        disc.layer.cornerRadius = diameter / 2
        disc.isUserInteractionEnabled = false
        let cross = UIImageView(image: UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)))
        cross.tintColor = .white
        cross.contentMode = .center
        cross.frame = disc.bounds
        disc.addSubview(cross)
        item.removeButton.addSubview(disc)
        item.removeButton.accessibilityLabel = String(localized: "conversation.composer.removeAttachment", defaultValue: "Remove attachment", bundle: .module)
        item.removeButton.addAction(UIAction { [weak self] _ in self?.onRemove?(id) }, for: .touchUpInside)
        item.view.addSubview(item.removeButton)
        return item
    }

    private func styleCorners(_ item: Item) {
        item.imageView.layer.cornerRadius = previewCornerRadius
        item.imageView.layer.cornerCurve = .continuous
    }

    /// Messages' shelf spring: critically damped, 0.345 s response.
    static func animate(delay: TimeInterval = 0, _ animations: @escaping () -> Void, completion: (() -> Void)? = nil) {
        UIView.animate(
            springDuration: Motion.springResponse, bounce: 0, initialSpringVelocity: 0, delay: delay,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: animations, completion: { _ in completion?() }
        )
    }
}
#endif
