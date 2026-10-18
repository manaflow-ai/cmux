public import QuartzCore

/// When the Core Animation commit that carries a change ends (debug timing; macOS has no
/// `CATransaction` commit handler). An empty 1-point layer in `host` (drawn nowhere): ``mark()``
/// asks for its display, so Core Animation displays it inside the commit of the current
/// transaction, and the run loop block queued from there runs once that commit's run loop source
/// returns: `onCommit` gets that time (`CACurrentMediaTime`). On macOS 26 the update cycle commits
/// once per frame from its own run loop source, not at the run loop's idle (cx-8w027.25).
@MainActor
public final class CommitProbe {
    private final class Layer: CALayer {
        var onCommit: (@MainActor (CFTimeInterval) -> Void)?

        override func display() {
            let onCommit = onCommit
            // wakeup-allow: one block per probe display, only while a debug probe records
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { onCommit?(CACurrentMediaTime()) } // main-proof: queued on the main run loop
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private let layer = Layer()

    public init(host: CALayer, onCommit: @escaping @MainActor (CFTimeInterval) -> Void) {
        layer.onCommit = onCommit
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        host.addSublayer(layer)
    }

    /// The commit of the transaction open now reports its end.
    public func mark() { layer.setNeedsDisplay() }

    public func remove() { layer.removeFromSuperlayer() }
}
