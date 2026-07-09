public import AppKit

/// A resolved hosted Web Inspector divider pairing within a browser window
/// portal slot: the slot, the split container, and the page/inspector view pair
/// the draggable divider sits between, plus the side the inspector docks to.
///
/// WebKit injects its own split view when a Web Inspector docks beside a hosted
/// page. The portal pulls that internal divider's drag through to resize the
/// page and inspector frames. `HostedInspectorDividerFinder` discovers the best
/// such pairing within a slot; the app then maps the hit (together with its
/// concrete `WindowBrowserSlotView`) into live drag state and frame mutation.
/// Every view is typed `NSView` so this value stays decoupled from the app's
/// `WindowBrowserSlotView`.
public struct HostedInspectorDividerHit {
    /// The portal slot view the inspector pairing was found in.
    public let slotView: NSView
    /// The split container whose subviews hold the page and the inspector.
    public let containerView: NSView
    /// The hosted page view on one side of the divider.
    public let pageView: NSView
    /// The hosted Web Inspector view on the other side of the divider.
    public let inspectorView: NSView
    /// Which side of the page the inspector docks to.
    public let dockSide: HostedInspectorDockSide

    /// Create a hosted inspector divider hit from its resolved views and dock side.
    public init(
        slotView: NSView,
        containerView: NSView,
        pageView: NSView,
        inspectorView: NSView,
        dockSide: HostedInspectorDockSide
    ) {
        self.slotView = slotView
        self.containerView = containerView
        self.pageView = pageView
        self.inspectorView = inspectorView
        self.dockSide = dockSide
    }
}
