public import AppKit

/// The root view of a pane's content that is no ``PaneCommitSurface`` itself and holds some: a container of tabs whose
/// shown tab is a terminal or a page. It names them, so a layout change finds them with no walk of the content's views.
///
/// ```swift
/// extension TabContainerView: PaneCommitSurfaceHosting {
///     var commitSurfaces: [any PaneCommitSurface] { shownTab.map { [$0.surface] } ?? [] }
/// }
/// ```
///
/// In a test, a plain `NSView` subclass that returns a list of fake surfaces is enough: the layout reads this one
/// property and calls ``PaneCommitSurface/commitWillResize(by:ready:)`` on each surface it gets.
@MainActor
public protocol PaneCommitSurfaceHosting: NSView {
    /// The surfaces that show in this content now: the shown tab's, never a parked tab's or a hidden view's.
    ///
    /// Read once per resized pane in a layout change's own turn, so it must be cheap: a stored reference, no walk of
    /// the view tree. Each surface it names hears its new size and the commit waits for its report.
    var commitSurfaces: [any PaneCommitSurface] { get }
}
