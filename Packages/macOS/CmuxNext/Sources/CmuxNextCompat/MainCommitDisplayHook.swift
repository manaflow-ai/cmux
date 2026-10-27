public import QuartzCore

/// Runs main-actor work once inside the Core Animation commit of the main thread's open transaction,
/// after AppKit's layout and display of the window and before the encode, so what the work changes ships
/// in that same commit.
///
/// macOS has no public `CATransaction` commit handler (`addCommitHandler(_:forPhase:)` is not in the
/// macOS SDK), and a main run-loop observer added during AppKit's display cycle runs only after the
/// commit that cycle belongs to. Core Animation does display, inside the commit, every layer of a
/// committed tree that needs display: ``run(in:_:)`` joins an empty 1-point layer (drawn nowhere, no
/// actions) to `host` and asks for its display, and its `display()` runs the work. That holds for a call
/// from inside AppKit's layout or display too; with no transaction open, the call makes the implicit one,
/// committed at the end of the run-loop turn. The layer is the debug `CommitProbe`'s (CmuxNextDesign), here for work.
///
/// ```swift
/// let hook = MainCommitDisplayHook()
/// hook.run(in: window.contentView!.layer!) { presenter.presentPending() }
/// ```
@MainActor
public final class MainCommitDisplayHook {
    private nonisolated final class Layer: CALayer {
        /// The work of the next display; taken by that display, so a display Core Animation adds on its
        /// own (a new contents scale) runs nothing.
        var onDisplay: (@MainActor () -> Void)?

        override func display() {
            let body = onDisplay
            onDisplay = nil
            // main-proof: the layer joins only layer trees of windows, from the main actor (`run(in:_:)`),
            // and Core Animation displays those in the main thread's commit.
            MainActor.assumeIsolated { body?() }
        }

        /// No implicit animation when the layer joins or leaves a host.
        override func action(forKey event: String) -> (any CAAction)? { nil }
    }

    private let layer = Layer()

    /// Makes a hook; it joins a layer tree only at ``run(in:_:)``.
    public init() {
        layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    /// `body` runs once inside the commit that carries `host`'s tree; it replaces work given earlier that
    /// has not run yet. The hook (re)joins `host` first, since a layer outside a committed tree is never
    /// displayed. `host` is a window's layer (for example its content view's).
    public func run(in host: CALayer, _ body: @escaping @MainActor () -> Void) {
        layer.onDisplay = body
        if layer.superlayer !== host { host.addSublayer(layer) }
        layer.setNeedsDisplay()
    }

    /// Leaves the host; work given and not run yet never runs.
    public func remove() {
        layer.onDisplay = nil
        layer.removeFromSuperlayer()
    }
}
