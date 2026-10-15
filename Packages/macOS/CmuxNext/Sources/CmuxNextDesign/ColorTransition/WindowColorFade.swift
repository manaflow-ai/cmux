public import AppKit

/// The crossfade half of the color transition (cx-3rf4z): for what has no single color to blend
/// (terminal surfaces, chrome that draws its own text and fills), the window's last composited
/// frame lies over it and fades out on the transition's curve. The image is the window as the
/// window server shows it now, so a second change during a fade starts from the blend on screen
/// (a `CATransition` restarted from the model state and jumped). One per window; `regions` limit
/// the fade to some views (a workspace switch fades the sidebar and titlebar, never the content
/// swap).
@MainActor
final class WindowColorFade {
    private static var associationKey: UInt8 = 0
    private var overlays: [CALayer] = []
    private var generation = 0

    static func forWindow(_ window: NSWindow) -> WindowColorFade {
        if let fade = objc_getAssociatedObject(window, &associationKey) as? WindowColorFade { return fade }
        let fade = WindowColorFade()
        objc_setAssociatedObject(window, &associationKey, fade, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return fade
    }

    /// Lays the window's current frame over `regions` (nil: the whole window) and fades it out with
    /// `transition`. Call it before the change commits; an instant transition, a window off screen
    /// or a failed capture fades nothing.
    func fade(_ window: NSWindow, regions: [NSView]?, transition: ColorTransition) {
        guard !transition.isInstant, window.isVisible, window.occlusionState.contains(.visible),
              let host = window.contentView, let hostLayer = host.layer,
              let image = window.compositedSnapshot(includeChild: { _ in false }) else { return }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let scale = CGFloat(image.width) / frame.width
        let rects = regions.map { views in
            views.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }.map { $0.convert($0.bounds, to: nil) }
        } ?? [CGRect(origin: .zero, size: frame.size)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeOverlays()
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let pixels = CGRect(x: rect.minX * scale, y: (frame.height - rect.maxY) * scale,
                                width: rect.width * scale, height: rect.height * scale).integral
            guard let crop = image.cropping(to: pixels) else { continue }
            let layer = CALayer()
            layer.contents = crop
            layer.contentsGravity = .resize
            layer.frame = host.convert(rect, from: nil)
            layer.zPosition = 100_000
            layer.opacity = 0
            hostLayer.addSublayer(layer)
            overlays.append(layer)
        }
        CATransaction.commit()
        guard !overlays.isEmpty else { return }
        generation += 1
        let current = generation
        let samples = transition.progressSamples(count: ColorTransition.keyframes)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current else { return }
            self.removeOverlays()
        }
        for layer in overlays {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = samples.map { Float(1 - min(max($0, 0), 1)) }
            animation.keyTimes = samples.indices.map { NSNumber(value: Double($0) / Double(samples.count - 1)) }
            animation.calculationMode = .linear
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.duration = transition.seconds
            layer.add(animation, forKey: "cmux.colorFade")
        }
        CATransaction.commit()
    }

    private func removeOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in overlays { layer.removeFromSuperlayer() }
        CATransaction.commit()
        overlays.removeAll()
    }
}
