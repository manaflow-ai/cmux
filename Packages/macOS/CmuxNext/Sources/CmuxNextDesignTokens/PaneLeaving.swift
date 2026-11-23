/// The view that holds one pane in a layout, for what the pane's content shows of the pane's state (its tab bar).
///
/// A close takes a pane out of its layout in the key's turn (so does a zoom of another pane, for each pane that it
/// covers), and the frame that shows the layout without the pane hides the pane's view. Between the two the view shows
/// as it was. The content asks this, so that what it shows of the pane goes with that frame and not before it.
/// A view in the pane asks it through `NSView.isInALeavingPane` (`CmuxNextDesign/NSView+LeavingPane.swift`).
@MainActor
public protocol PaneLeaving: AnyObject {
    /// The pane left its layout in a change that has not shown yet: its view shows as it was until that change shows.
    var isLeaving: Bool { get }
}
