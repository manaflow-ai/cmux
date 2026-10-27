/// How much of a thing a person can see: the state a ``VisibilityNode`` holds and propagates
/// (plans/cmux-next/chrome-parity/p06-scheduler.md, section B).
///
/// The same three values as Chromium's `content::Visibility`
/// (`content/public/browser/visibility.h`): an NSWindow occlusion change feeds `occluded`, a
/// hidden app, a parked workspace or an unselected tab feeds `hidden`. The order is
/// `hidden < occluded < visible`, so a node's effective value is `min(own, parent)`: a child can
/// never show more than its parent.
public enum Visibility: Int, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    /// Not shown at all: a hidden app, a miniaturized window, a parked workspace, an unselected
    /// tab, a row outside the viewport and its overscan.
    case hidden
    /// Laid out in a shown place but covered: an occluded window, or displays that sleep. It
    /// draws nothing a person sees, but it keeps its layout ready.
    case occluded
    /// On screen.
    case visible

    public static func < (lhs: Visibility, rhs: Visibility) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether this value is ``visible``.
    public var isVisible: Bool { self == .visible }

    public var description: String {
        switch self {
        case .hidden: "hidden"
        case .occluded: "occluded"
        case .visible: "visible"
        }
    }
}
