import CCmuxScreenKit
import CoreGraphics
import Foundation
import QuartzCore

/// Follow mode's camera: a crop of the shared display that follows what the
/// person on the Mac does (pointer, text caret, focused window, changed
/// pixels). The screen view asks it once per display frame and shows the
/// crop by setting its zoom and offset; all motion comes from the camera.
///
/// The app supplies the camera (`ScreenSession.camera`); this package only
/// drives it, so it links no engine of its own. Rects are fractions of the
/// shared display (0...1 on each axis, origin top left), so the camera never
/// needs the view's layout and the view never needs the Mac's pixels.
@MainActor
public protocol ScreenCamera: AnyObject {
    /// The Mac sends focus signals (an older Mac sends none: no Follow button).
    var isAvailable: Bool { get }
    /// Follow is on: the view shows `crop(at:aspect:)` every frame.
    var isFollowing: Bool { get }
    /// The person took the camera (a pinch or a drag) and has not handed it back.
    var isHeld: Bool { get }
    /// The crop to show at `time` (`CACurrentMediaTime`'s clock) in a view of
    /// `aspect` (its width over its height), as a fraction of the display; nil
    /// leaves the view where it is (Follow is off, or the person holds it).
    func crop(at time: CFTimeInterval, aspect: CGFloat) -> CGRect?
    /// The person pinched or dragged: the camera holds `visible` (a fraction
    /// of the display) until a tap.
    func personMoved(_ visible: CGRect)
    /// A tap on the screen. True when it handed a held camera back to Follow;
    /// that tap then clicks nothing on the Mac.
    func personTapped() -> Bool
    /// The chrome's Follow button: on, back to Follow from held, or off.
    func toggle()
}

/// Where the view's scroll view must be to show `crop` of `display`
/// (cmux-rd-core `screen_kit::framing`): the
/// zoom that fits the whole crop in the view, and the content offset that
/// centres it there. A crop taller than the view's shape (a readable-width
/// portrait crop of a landscape screen) shows letterboxed above and below.
public struct ScreenCameraFraming: Equatable, Sendable {
    public var zoomScale: CGFloat
    public var contentOffset: CGPoint

    /// `crop` is a fraction of `display` (its rect in the scroll view's
    /// unzoomed content); `viewSize` is the scroll view's bounds.
    public init(crop: CGRect, display: CGRect, viewSize: CGSize) {
        self.init(cmux_screen_framing(CmuxScreenRect(crop), CmuxScreenRect(display), CmuxScreenSize(viewSize)))
    }

    init(_ framing: CmuxScreenFraming) {
        self.init(zoomScale: framing.zoom_scale, contentOffset: CGPoint(framing.content_offset))
    }

    public init(zoomScale: CGFloat, contentOffset: CGPoint) {
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
    }

    /// The part of `display` the view shows at this zoom and offset (a
    /// fraction of it, cut to the display): what the person framed by hand.
    public func visible(display: CGRect, viewSize: CGSize) -> CGRect {
        let framing = CmuxScreenFraming(zoom_scale: zoomScale, content_offset: CmuxScreenPoint(contentOffset))
        return CGRect(cmux_screen_framing_visible(framing, CmuxScreenRect(display), CmuxScreenSize(viewSize)))
    }
}
