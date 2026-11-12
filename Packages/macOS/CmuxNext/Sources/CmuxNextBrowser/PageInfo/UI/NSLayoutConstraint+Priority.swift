import AppKit

extension NSLayoutConstraint {
    /// This constraint at `priority`, for an inline `NSLayoutConstraint.activate` list.
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
