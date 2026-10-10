#if canImport(UIKit)
import CmuxConversationGeometry
import CoreImage
import UIKit

/// The arrow a swipe-to-reply uncovers: Messages' `CKSwipeActionIndicator`,
/// `arrowshape.turn.up.backward.fill` fitted to 26 pt in system gray 2,
/// parked behind the bubble's resting leading edge. It grows from 0.4 to 1
/// while sharpening from a 4.5 pt blur and fading in; an outgoing bubble's
/// arrow drifts 12 pt left as it grows.
final class ReplySwipeIndicator: UIView {
    static let size: CGFloat = 26

    private let sharp = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.backward.fill"))
    /// Core Animation's gaussian blur filter isn't public, so the blur is a
    /// pre-blurred copy cross-faded against the sharp arrow.
    private let blurred = UIImageView()
    private var scale = ConversationReplyMotion.indicatorInitialScale
    private var drift: CGFloat = 0
    private var center0 = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        for view in [blurred, sharp] {
            view.contentMode = .scaleAspectFit
            view.tintColor = .systemGray2
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        reset()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // Every cell entering the transcript passes through here; the blur is
        // only drawn once a swipe uncovers the arrow (`update`), from a cache.
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            blurred.image = nil
        }
    }

    func place(at center: CGPoint) {
        center0 = center
        bounds = CGRect(x: 0, y: 0, width: Self.size, height: Self.size)
        self.center = center
    }

    /// `progress` 0...1 as the bubble travels from 22 to 40 pt.
    func update(progress: CGFloat, isOutgoing: Bool) {
        if blurred.image == nil { blurred.image = Self.blurredArrow(traits: traitCollection) }
        let blur = 1 - progress
        sharp.alpha = progress * (1 - blur)
        blurred.alpha = progress * blur
        // Visible while any part shows (UIView alpha is what fades it out on release).
        alpha = progress > 0 ? 1 : 0
        setTransform(scale: ConversationReplyMotion.indicatorScale(forProgress: progress),
                     drift: isOutgoing ? -ConversationReplyMotion.outgoingIndicatorDrift * progress : 0)
    }

    /// Committing: a 0.3 s pulse to 1.15 and back (eased as a whole), the
    /// haptic a quarter of the way in.
    func pulse(isOutgoing: Bool, haptic: @escaping () -> Void) {
        sharp.alpha = 1
        blurred.alpha = 0
        alpha = 1
        let drift = isOutgoing ? -ConversationReplyMotion.outgoingIndicatorDrift : 0
        let start = layer.presentation()?.affineTransform() ?? transform
        setTransform(scale: ConversationReplyMotion.indicatorFinalScale, drift: drift)
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [
            CATransform3DMakeAffineTransform(start),
            CATransform3DMakeAffineTransform(Self.transform(scale: ConversationReplyMotion.indicatorPulseScale, drift: drift)),
            CATransform3DMakeAffineTransform(transform),
        ]
        animation.keyTimes = [0, 0.25, 1]
        animation.duration = ConversationReplyMotion.pulseDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "replyPulse")
        let timer = UIViewPropertyAnimator(duration: ConversationReplyMotion.pulseDuration / 4, curve: .linear)
        timer.addAnimations {}
        timer.addCompletion { _ in haptic() }
        timer.startAnimation()
    }

    /// Release without replying: back to 0.4 and transparent over 0.4 s,
    /// keeping its drift. A reply hides it at once instead (`reset`): its
    /// row hides behind the thread's copy on the very next frame.
    func settle() {
        let drift = self.drift
        UIView.animate(withDuration: ConversationReplyMotion.indicatorResetDuration, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.setTransform(scale: ConversationReplyMotion.indicatorInitialScale, drift: drift)
            self.alpha = 0
        }
    }

    func reset() {
        layer.removeAllAnimations()
        alpha = 0
        setTransform(scale: ConversationReplyMotion.indicatorInitialScale, drift: 0)
    }

    private func setTransform(scale: CGFloat, drift: CGFloat) {
        self.scale = scale
        self.drift = drift
        transform = Self.transform(scale: scale, drift: drift)
    }

    /// Scale, then translate in the scaled space (CGAffineTransformTranslate
    /// after CGAffineTransformScale), as ChatKit composes it.
    private static func transform(scale: CGFloat, drift: CGFloat) -> CGAffineTransform {
        CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: drift, y: 0)
    }

    /// Rendered blurs by color and scale: Core Image is far too slow to run
    /// per cell, and every arrow in one appearance is the same image.
    private static var blurCache: [String: UIImage] = [:]

    private static var blurWarming: Set<String> = []

    private static func blurKey(traits: UITraitCollection) -> (key: String, color: UIColor, scale: CGFloat) {
        let color = UIColor.systemGray2.resolvedColor(with: traits)
        let scale = traits.displayScale > 0 ? traits.displayScale : 3
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return ("\(red),\(green),\(blue),\(alpha)@\(scale)", color, scale)
    }

    private static func blurredArrow(traits: UITraitCollection) -> UIImage? {
        let (key, color, scale) = blurKey(traits: traits)
        if let cached = blurCache[key] { return cached }
        let image = renderBlurredArrow(color: color, scale: scale)
        if let image { blurCache[key] = image }
        return image
    }

    /// Renders the blur for `traits` off the main thread ahead of the first
    /// swipe, so uncovering the arrow never waits on Core Image.
    static func prewarm(traits: UITraitCollection) {
        let (key, color, scale) = blurKey(traits: traits)
        guard blurCache[key] == nil, !blurWarming.contains(key) else { return }
        blurWarming.insert(key)
        Task {
            let image = await Task.detached(priority: .utility) { renderBlurredArrow(color: color, scale: scale) }.value
            blurWarming.remove(key)
            if let image, blurCache[key] == nil { blurCache[key] = image }
        }
    }

    nonisolated private static func renderBlurredArrow(color: UIColor, scale: CGFloat) -> UIImage? {
        guard let symbol = UIImage(systemName: "arrowshape.turn.up.backward.fill")?
            .withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let box = CGRect(x: 0, y: 0, width: size, height: size)
        let fitted = fittedRect(symbol.size, in: box)
        let sharpImage = UIGraphicsImageRenderer(bounds: box, format: format).image { _ in symbol.draw(in: fitted) }
        guard let input = CIImage(image: sharpImage), let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(ConversationReplyMotion.indicatorInitialBlurRadius * scale / 2, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    nonisolated private static func fittedRect(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * s, height: size.height * s)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}
#endif
