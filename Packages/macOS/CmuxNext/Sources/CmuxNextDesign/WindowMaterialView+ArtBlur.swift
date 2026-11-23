import AppKit

/// The still picture's blur under Frosted (``BackdropArtBlur``): what the art layer shows, and the
/// blur being made.
final class ArtBlurState {
    /// How a blur was made: from which picture, by how much, at which fill and backing scale.
    struct Made {
        let source: NSImage
        let radius: Int
        let pointsPerPixel: CGFloat
        let scale: CGFloat
    }

    /// The blurred picture shown now and how it was made.
    var shown: (made: Made, image: NSImage)?
    /// The blur being made and how; tests await the task's `value`.
    var pending: Made?
    var task: Task<Void, Never>?

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}

extension WindowMaterialView {
    /// Puts the right picture in the art layer: the art itself, or under Frosted its blurred copy
    /// (``BackdropArtBlur``), made again off the main actor when the art, the radius, the backing
    /// scale or the shown size moved past ``BackdropArtBlur/refillTolerance``. While a blur is made
    /// the layer keeps what it shows, then crossfades to it (``showBlurredArt(_:)``). A live resize
    /// keeps the blur it has (the layer stretches it with the picture) and makes it again when the
    /// resize ends.
    func refreshArtBlur() {
        guard let source = artImage, artBlurRadius > 0, !hidesArt,
              let picture = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            artBlur.cancel()
            artBlur.shown = nil
            if let layer = artView.layer, (layer.contents as AnyObject?) !== artImage { layer.contents = artImage }
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let fill = bounds.isEmpty ? CGSize(width: CGFloat(picture.width) / scale, height: CGFloat(picture.height) / scale) : bounds.size
        let want = ArtBlurState.Made(source: source, radius: artBlurRadius,
                                     pointsPerPixel: BackdropArtBlur.pointsPerPixel(width: picture.width, height: picture.height, fill: fill),
                                     scale: scale)
        let fits = { (made: ArtBlurState.Made, sized: Bool) in
            made.source === want.source && made.radius == want.radius && made.scale == want.scale
                && (!sized || abs(want.pointsPerPixel / made.pointsPerPixel - 1) <= BackdropArtBlur.refillTolerance)
        }
        if let shown = artBlur.shown, fits(shown.made, !inLiveResize) {
            if let layer = artView.layer, (layer.contents as AnyObject?) !== shown.image { layer.contents = shown.image }
            return
        }
        if let pending = artBlur.pending, fits(pending, true) { return }
        artBlur.cancel()
        artBlur.pending = want
        let input = SendableCGImage(image: picture), radius = want.radius
        artBlur.task = Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) {
                BackdropArtBlur.blurred(input.image, radius: radius, fill: fill, scale: scale).map(SendableCGImage.init)
            }.value
            guard !Task.isCancelled, let self, let made else { return }
            let image = NSImage(cgImage: made.image, size: NSSize(width: made.image.width, height: made.image.height))
            self.artBlur.pending = nil
            self.artBlur.task = nil
            self.artBlur.shown = (want, image)
            self.showBlurredArt(image)
        }
    }

    /// Shows a blur just made: crossfading from the picture shown (`MotionFade.wallpaper`), or
    /// fading in when none was, as art that loads does.
    private func showBlurredArt(_ image: NSImage) {
        guard let layer = artView.layer else { return }
        let from = layer.presentation()?.contents ?? layer.contents
        let animates = (window?.isVisible == true || crossfadesOffScreen) && !Motion.reduceMotion
        layer.contents = image
        if animates, let from {
            Motion.panes.set(layer, "contents", to: image, fade: .wallpaper, from: from)
        } else if animates {
            Motion.panes.set(layer, "opacity", to: artOpacity, fade: .fadeIn, from: 0)
        }
    }
}
