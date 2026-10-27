public import AppKit

extension NSView {
    /// Frames the view so its alignment rect is `rect` (a ``ChipLayout`` frame, an Auto Layout-free
    /// layout's output); sets nothing when the frame is already there.
    public func setAlignmentFrame(_ rect: CGRect) {
        let frame = frame(forAlignmentRect: rect)
        if self.frame != frame { self.frame = frame }
    }
}
