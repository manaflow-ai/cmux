import AppKit

extension NSLayoutConstraint {
    /// Sets the priority inline, for constraint lists.
    func prioritized(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
