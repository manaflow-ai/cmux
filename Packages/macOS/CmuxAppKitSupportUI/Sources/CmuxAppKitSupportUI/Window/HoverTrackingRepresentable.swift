import AppKit
public import SwiftUI

/// A SwiftUI overlay that hosts a ``HoverTrackingNSView`` to detect pointer hover
/// through an `NSTrackingArea`, forwarding enter/exit as a `Bool` through a closure.
public struct HoverTrackingRepresentable: NSViewRepresentable {
    /// Invoked with `true` when the pointer enters and `false` when it exits.
    public let onChange: (Bool) -> Void

    /// Creates a hover-tracking overlay.
    /// - Parameter onChange: Invoked with the new hover state on enter/exit.
    public init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    public func makeNSView(context: Context) -> HoverTrackingNSView {
        HoverTrackingNSView(onChange: onChange)
    }

    public func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onChange = onChange
    }
}
