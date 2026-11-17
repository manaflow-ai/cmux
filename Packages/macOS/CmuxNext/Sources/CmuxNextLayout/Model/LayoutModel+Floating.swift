public import CoreGraphics

/// Floating panes (`floating-panes-v1`): a pane the tiled layout leaves out, shown above the tiled panes in a frame
/// of its own (``LayoutScreen/floating``). The daemon owns the list and each frame. A pointer's move or resize is
/// local in the view until its release, which becomes one `setFloatingFrame` intent.
extension LayoutModel {
    /// Gives the floating pane `pane` the frame `frame` (fractions of the pane area, held to the limits of
    /// ``LayoutFloatingPane/limited(_:)``): shown at once, and sent as one intent. False when `pane` does not float.
    @discardableResult
    public func setFloatingFrame(_ pane: PaneID, frame: CGRect) -> Bool {
        let frame = LayoutFloatingPane.limited(frame)
        guard screens.contains(where: { $0.floats(pane) }) else { return false }
        showLocally { screens in
            for screen in screens.indices {
                guard let index = screens[screen].floating.firstIndex(where: { $0.pane == pane }) else { continue }
                screens[screen].floating[index].frame = frame
            }
        }
        emit(.setFloatingFrame(pane, frame: frame))
        return true
    }
}
