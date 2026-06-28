public import AppKit

extension NSResponder {
    /// Whether `target` appears in this responder's next-responder chain,
    /// starting at the receiver and following `nextResponder` for at most 64
    /// hops (a guard against a cyclic or pathologically deep chain). Returns
    /// `true` as soon as a link is identical (`===`) to `target`. Used to decide
    /// whether the window's first responder currently sits inside a browser
    /// web view.
    public func chainContains(_ target: NSResponder) -> Bool {
        var current: NSResponder? = self
        var hops = 0
        while let responder = current, hops < 64 {
            if responder === target { return true }
            current = responder.nextResponder
            hops += 1
        }
        return false
    }
}
