public import AppKit

extension NSView {
    /// Mounts `view` hidden at this view's size (a view built before it shows, such as the next Cmd-N's workspace):
    /// it enters the window now, so showing it later is only an unhide, with no window entry and no new size.
    public func addHiddenSubview(_ view: NSView) {
        view.isHidden = true
        view.frame = bounds
        addSubview(view)
    }
}
