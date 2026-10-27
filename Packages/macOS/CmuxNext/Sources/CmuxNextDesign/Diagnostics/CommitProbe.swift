public import QuartzCore

/// When the Core Animation commit that carries a change runs (debug timing; macOS has no
/// `CATransaction` commit handler). An empty 1-point layer in `host` (drawn nowhere): ``mark()``
/// asks for its display, so Core Animation displays it inside the commit of the current
/// transaction, after AppKit's layout and display of the window and before the encode and the
/// window-server transaction; the run loop block queued from there runs once that commit's run
/// loop source returns (an upper bound of the commit's end). `onCommit` gets both times (`CACurrentMediaTime`). On macOS 26 the update
/// cycle commits once per frame from its own run loop source, not at the run loop's idle (cx-8w027.25).
@MainActor
public final class CommitProbe {
    private nonisolated final class Layer: CALayer {
        var onCommit: (@MainActor (_ displayed: CFTimeInterval, _ ended: CFTimeInterval) -> Void)?

        override func display() {
            let onCommit = onCommit, displayed = CACurrentMediaTime()
            // wakeup-allow: one block per probe display, only while a debug probe records
            // main-hop-allow: the probe times the commit's end, so its block runs when the commit's run loop source returns; a posted task would time the queue
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { onCommit?(displayed, CACurrentMediaTime()) } // main-proof: queued on the main run loop
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private let layer = Layer()

    public init(onCommit: @escaping @MainActor (_ displayed: CFTimeInterval, _ ended: CFTimeInterval) -> Void) {
        layer.onCommit = onCommit
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// The commit of the transaction open now reports its times; the probe (re)joins `host` first,
    /// since a layer outside a committed tree is never displayed.
    public func mark(in host: CALayer) {
        if layer.superlayer !== host { host.addSublayer(layer) }
        layer.setNeedsDisplay()
    }

    public func remove() { layer.removeFromSuperlayer() }
}
