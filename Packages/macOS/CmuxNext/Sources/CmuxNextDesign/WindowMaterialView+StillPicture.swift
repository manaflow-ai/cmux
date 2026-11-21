public import AppKit
import CmuxNextDesignTokens

/// What a window's backdrop shows under the window's content, when that is one still picture of ours with one tint
/// over it. The picture covers what is behind the window, so a view over the backdrop can show the same pixels as
/// the backdrop does at a place: a copy of the picture's layer with the tint over it (the layout's panes do that
/// while they move, `PaneCommitMotion+Sheet`). A value: it holds no view.
public struct WindowStillPicture {
    /// The picture, as the art's layer has it.
    public let contents: Any
    /// The art layer's frame in its window's coordinates.
    public let frame: CGRect
    /// How the art's layer fits the picture in its frame.
    public let gravity: CALayerContentsGravity
    /// The art layer's `contentsScale`.
    public let scale: CGFloat
    /// The tint over the picture, as it shows; nil: no tint.
    public let tint: CGColor?

    /// Whether `other` shows the same pixels: the same picture at the same place, with the same tint.
    public func isSame(as other: WindowStillPicture) -> Bool {
        let one = contents as AnyObject, two = other.contents as AnyObject
        return one === two && frame == other.frame && gravity == other.gravity && scale == other.scale && tint == other.tint
    }
}

/// Why a window's backdrop is no still picture of ours (``WindowMaterialView/stillPicture``).
public nonisolated enum WindowPictureGap: String, Sendable, CaseIterable {
    /// The backdrop shows no picture: an opaque window, or what is behind the window with only the tint.
    case noPicture
    /// Liquid Glass: it shows what is behind the window.
    case glass
    /// A video plays over the picture.
    case video
    /// A living wallpaper draws over the picture.
    case shader
    /// The picture is blurred by a filter on its layer.
    case blur
    /// The picture lets what is behind the window show through it.
    case seeThrough
    /// The picture or the tint changes now (a crossfade to a new picture, a fade in, a colour blend).
    case changing
}

/// What a window's backdrop shows: one still picture, or why not.
public enum WindowPictureGround {
    /// One still picture with its tint.
    case still(WindowStillPicture)
    /// No still picture, and why.
    case gap(WindowPictureGap)
}

extension WindowMaterialView {
    /// The still picture that this backdrop shows now with its tint, or why it shows none. It reads what the view's
    /// layers have, so it is true for the frame of the turn that reads it.
    public var stillPicture: WindowPictureGround {
        if case .glass = material { return .gap(.glass) }
        guard material != .opaque, !artView.isHidden, let art = artView.layer, let contents = art.contents else { return .gap(.noPicture) }
        if showsVideo { return .gap(.video) }
        if showsShader { return .gap(.shader) }
        if artBlurRadius > 0 || !(art.filters ?? []).isEmpty { return .gap(.blur) }
        if artOpacity < 1 || art.opacity < 1 { return .gap(.seeThrough) }
        let tint = shownTintLayer
        if !(art.animationKeys() ?? []).isEmpty || !(tint?.animationKeys() ?? []).isEmpty { return .gap(.changing) }
        let frame = artView.convert(artView.bounds, to: nil)
        return .still(WindowStillPicture(contents: contents, frame: frame, gravity: art.contentsGravity, scale: art.contentsScale,
                                         tint: tint?.backgroundColor))
    }
}
