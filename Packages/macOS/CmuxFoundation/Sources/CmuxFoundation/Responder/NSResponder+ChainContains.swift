public import AppKit

extension NSResponder {
    /// Walks the next-responder chain starting at `self`, returning `true` when
    /// `target` is reached within 64 hops (the legacy bound that guards against a
    /// cyclic chain).
    ///
    /// This is the single home of the responder-chain membership test that the
    /// browser-focus and synthetic-input paths used to duplicate as a per-type
    /// `static func responderChainContains(_:target:)`. Call it on the optional
    /// start responder (e.g. `window.firstResponder?.responderChain(contains:)
    /// ?? false`); a `nil` start chains to `false`, matching the legacy helper
    /// that returned `false` for a `nil` start.
    public func responderChain(contains target: NSResponder) -> Bool {
        var responder: NSResponder? = self
        var hops = 0
        while let current = responder, hops < 64 {
            if current === target { return true }
            responder = current.nextResponder
            hops += 1
        }
        return false
    }
}
