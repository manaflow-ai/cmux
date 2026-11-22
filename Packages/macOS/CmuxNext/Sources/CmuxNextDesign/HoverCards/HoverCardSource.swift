public import AppKit

/// What a hit test found: a target and its frame on screen.
public struct HoverCardHit {
    public var target: HoverTarget
    public var anchor: CGRect
    public init(target: HoverTarget, anchor: CGRect) {
        self.target = target
        self.anchor = anchor
    }
}

/// A card body a source supplies: its view (reused per kind), where the
/// card goes, the view whose theme scope it draws in, and its recolor.
public struct HoverCardBody {
    public var view: NSView
    public var placement: HoverCardPlacement
    public weak var themeAnchor: NSView?
    public var applyTheme: () -> Void
    public init(view: NSView, placement: HoverCardPlacement, themeAnchor: NSView?, applyTheme: @escaping () -> Void) {
        self.view = view
        self.placement = placement
        self.themeAnchor = themeAnchor
        self.applyTheme = applyTheme
    }
}

/// A view with hover card targets (a tab strip, a sidebar list).
public protocol HoverCardSource: AnyObject {
    /// The window the targets are in.
    var hoverCardWindow: NSWindow? { get }
    /// The target under `screenPoint`, if any (nil when cards must not show
    /// there now: a drag, a rename, an open editor).
    func hoverCardHit(at screenPoint: CGPoint) -> HoverCardHit?
    /// `id`'s frame on screen now; nil when it has no visible frame.
    func hoverCardAnchor(for id: HoverTargetID) -> CGRect?
    /// The body for `id`'s card, configured for it.
    func hoverCardBody(for id: HoverTargetID) -> HoverCardBody?
    /// `id`'s card became pending or shown (start sampling resources).
    func hoverCardActivated(_ id: HoverTargetID)
    /// `id`'s card is no longer pending or shown.
    func hoverCardDeactivated(_ id: HoverTargetID)
}
