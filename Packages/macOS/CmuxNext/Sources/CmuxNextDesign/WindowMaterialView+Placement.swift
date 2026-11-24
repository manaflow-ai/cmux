public import AppKit
import CmuxNextCompat
public import CmuxNextDesignTokens

/// Where the picture lies (`appearance.backgroundPlacement`, Leo 2026-11-22: "we also want people to
/// be able to reposition the images easily"). A picture with no entry keeps the art view's own look:
/// the whole picture aspect-filled and centered, autoresizing with the window. A placed one draws in
/// the part of the view it covers, showing the matching part of the picture (`contentsRect`), laid
/// out again on each resize; a video over it is drawn in the same rect.
extension WindowMaterialView {
    /// The placement the shown picture draws with: Adjust Background…'s live one, else the
    /// setting's entry for it; nil when it has none.
    public var placement: BackdropPlacement? {
        if let previewPlacement { return previewPlacement }
        return BackdropPlacement.key(picture: shownPictureID).flatMap { DesignSettings.shared.backgroundPlacements[$0] }
    }

    /// The shown picture's size in points (nil without art), what Adjust Background… drags against.
    public var placementImageSize: CGSize? { artImage?.size }

    /// The id `appearance.backgroundPlacement` keys the shown picture by (``BackdropPlacement/key(picture:)``:
    /// a dynamic wallpaper's file, not its frame); nil without a picture.
    public var placementPictureID: String? {
        artImage == nil ? nil : BackdropPlacement.key(picture: shownPictureID)
    }

    /// Lays the art out again whenever `appearance.backgroundPlacement` changes
    /// (``DesignSettings/backgroundPlacements``, Observation).
    func observePlacement() {
        placementWatch = Task { [weak self] in
            for await _ in ObservationStream({ DesignSettings.shared.backgroundPlacements }) {
                guard let self else { return }
                self.applyPlacement()
            }
        }
    }

    /// Another picture came while Adjust Background… was open (chosen, even before it decodes, or
    /// shown): the overlay's placement is not this one's, so it is cancelled.
    func cancelAdjustingAnotherPicture() {
        guard let adjusting else { return }
        let id = BackdropPlacement.key(picture: shownPictureID)
        if adjusting.pictureID != id || artImage == nil { adjusting.cancel() }
    }

    /// Lays the art (and a video over it) out for ``placement``; unplaced art gets its own look back.
    func applyPlacement() {
        cancelAdjustingAnotherPicture()
        guard let layer = artView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let image = artImage?.size ?? .zero
        guard let placement, !placement.isCenteredFill, let shown = placement.layerFrame(image: image, in: bounds) else {
            videoView.place(nil, posterSize: nil)
            guard let look = unplacedArtLook else { return }
            unplacedArtLook = nil
            artView.autoresizingMask = [.width, .height]
            artView.frame = bounds
            artView.layerContentsPlacement = look.placement
            layer.contentsGravity = look.gravity
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            noteGlassSourceChange()
            return
        }
        if unplacedArtLook == nil {
            unplacedArtLook = (layer.contentsGravity, artView.layerContentsPlacement)
            artView.autoresizingMask = []
            artView.layerContentsPlacement = .scaleAxesIndependently
            layer.contentsGravity = .resize
        }
        videoView.place(placement, posterSize: image)
        guard artView.frame != shown.frame || layer.contentsRect != shown.contentsRect else { return }
        artView.frame = shown.frame
        layer.contentsRect = shown.contentsRect
        noteGlassSourceChange()
    }

    /// The whole drawn picture in window coordinates while a placement draws it (it may run past
    /// the view); nil while the art is aspect-filled into ``glassArtFrame``.
    var glassImageFrame: CGRect? {
        guard unplacedArtLook != nil, let placement, let image = artImage?.size,
              let drawn = placement.drawnFrame(image: image, in: bounds) else { return nil }
        return convert(drawn, to: nil)
    }
}
