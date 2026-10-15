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
    /// Overlays of an earlier fade a new one lies over: they keep fading underneath until the new
    /// fade ends, so the frame where the new image first reaches the screen never shows the live
    /// content bare.
    private var retiring: [CALayer] = []
    private var generation = 0
    /// The frame captured in this run loop turn: one change can fade twice (a workspace's roots,
    /// then its room's whole window); the second call must use the frame from before either, not
    /// a capture that may already show the first call's overlays.
    private var turnCapture: CGImage?

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
              let image = turnCapture ?? window.compositedSnapshot(includeChild: { _ in false }) else { return }
        if turnCapture == nil {
            turnCapture = image
            RunLoop.main.perform { [weak self] in self?.turnCapture = nil }
        }
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return }
        let scale = CGFloat(image.width) / frame.width
        let rects = regions.map { views in
            views.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }.map { $0.convert($0.bounds, to: nil) }
        } ?? [CGRect(origin: .zero, size: frame.size)]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        retiring += overlays
        overlays.removeAll()
        let z = 100_000 + CGFloat(retiring.count)
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let pixels = CGRect(x: rect.minX * scale, y: (frame.height - rect.maxY) * scale,
                                width: rect.width * scale, height: rect.height * scale).integral
            guard let crop = image.cropping(to: pixels).flatMap(Self.resident) else { continue }
            let layer = CALayer()
            layer.contents = crop
            layer.contentsGravity = .resize
            layer.frame = host.convert(rect, from: nil)
            layer.zPosition = z
            hostLayer.addSublayer(layer)
            overlays.append(layer)
        }
        CATransaction.commit()
        // The overlays reach the screen opaque before the change does: committed alone, their
        // first frame already shows the image (in the change's own commit a large new image could
        // miss its first frame and show the new colors bare for one frame).
        if !overlays.isEmpty { CATransaction.flush() }
        guard !overlays.isEmpty else {
            overlays = retiring
            retiring.removeAll()
            return
        }
        generation += 1
        let current = generation
        let samples = transition.progressSamples(count: ColorTransition.keyframes)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == current else { return }
            self.removeOverlays()
        }
        let opacities: [Any] = samples.map { Float(1 - min(max($0, 0), 1)) }
        for layer in overlays {
            layer.opacity = 0
            let animation = Motion.sampledKeyframes("opacity", values: opacities, duration: transition.seconds)
            layer.add(animation, forKey: "cmux.colorFade")
        }
        CATransaction.commit()
    }

    /// `image` copied into memory the render server can show at once (the window server's image
    /// can be backed lazily).
    private static func resident(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    private func removeOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in overlays + retiring { layer.removeFromSuperlayer() }
        CATransaction.commit()
        overlays.removeAll()
        retiring.removeAll()
    }
}
