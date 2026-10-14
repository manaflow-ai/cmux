import AppKit
import os

// cmux: real Messages blurs and darkens the header's avatar and name pill with the transcript under
// an open thread or reply view (thread-open-esc reference: the avatar 237 -> 103). The vendored
// window view keeps its thread layer (ThreadBackdrop, a live blur and tint, and the thread's rows)
// in its own layer tree, under the in-pane header (`PaneHeaderView`, AppKit views above that tree),
// so the header stayed sharp. As the morph and compose layers are hosted on their own (HostView
// install), the thread layer's CALayer moves to `threadHost`, a layer host above the header and
// below the selection, morph, field and compose hosts: the backdrop blurs and darkens the live
// header (its glass, title and avatar as drawn) on its own open and close curves, and the field
// stays above it. The thread layer view stays the window view's subview (frames, hit tests and
// scale walks are unchanged); only where its layer draws moves.
//
// The thread layer is the vendored `UIView` shim (appkit-port LayerViews.swift: an NSObject that
// owns a plain CALayer), not an NSView, so AppKit never re-attaches its layer; only the shim's own
// addSubview / insertSubview would (WindowView calls them for it in init only). `HostView.layout`
// checks the parent every pass and lifts it again if anything put it back.

extension HostView {
    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "home")

    /// The window view's thread layer view, by its stored property's name (`threadLayer`, private to
    /// WindowView.swift; read by reflection, no vendored edit). Nil if upstream renames or removes it.
    static func threadLayerView(of demo: MessagesWindowView) -> UIView? {
        Mirror(reflecting: demo).children.first { $0.label == "threadLayer" }?.value as? UIView
    }

    /// Moves the window view's thread layer into `threadHost` (install, and every layout pass when
    /// something moved it back). Logs a fault, and stops a DEBUG build, when the layer is not found:
    /// the header would stay sharp under an open thread (the 84ae154 baseline's gap).
    func liftThreadLayer(_ demo: MessagesWindowView) {
        if liftedThread == nil || liftedThread?.superview !== demo {
            liftedThread = Self.threadLayerView(of: demo)
            if liftedThread == nil {
                Self.log.fault("Home: the window view has no threadLayer; the header is not blurred under a thread")
                assertionFailure("MessagesWindowView.threadLayer not found (PaneHost+ThreadLayer.swift)")
                return
            }
        }
        guard let thread = liftedThread, thread.layer.superlayer !== threadHost.root else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        threadHost.root.addSublayer(thread.layer)
        CATransaction.commit()
    }

    /// The thread layer lives in `threadHost` (tests, the DEBUG socket).
    var threadLayerLifted: Bool {
        guard let demo, let thread = Self.threadLayerView(of: demo) else { return false }
        return thread.layer.superlayer === threadHost.root
    }
}
