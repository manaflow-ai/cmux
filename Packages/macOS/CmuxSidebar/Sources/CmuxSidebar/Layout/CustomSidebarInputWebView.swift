public import AppKit
public import WebKit

/// A hosted sidebar web view that transfers native keyboard ownership on pointer interaction.
///
/// A `WKWebView` can receive the click and update its DOM focus while the host window still treats
/// the previously focused terminal as its keyboard owner. The first character then reaches WebKit
/// during the click handoff, while later characters return to the terminal. This view moves AppKit's
/// first responder before WebKit handles the click and gives the host one hook to record that the
/// right sidebar, rather than the terminal, now owns keyboard focus.
@MainActor
public final class CustomSidebarInputWebView: WKWebView {
    /// Called immediately before AppKit transfers first-responder status to this web view.
    public var onRequestInputFocus: (@MainActor (NSWindow) -> Void)?

    public override func mouseDown(with event: NSEvent) {
        performPointerFocusHandoff {
            super.mouseDown(with: event)
        }
    }

    /// Runs the native focus handoff around one pointer action.
    ///
    /// Split out so tests can exercise the responder transition without manufacturing an `NSEvent`.
    ///
    /// - Parameter action: The WebKit pointer action to run after focus ownership transfers.
    public func performPointerFocusHandoff(_ action: () -> Void) {
        guard let window else {
            action()
            return
        }
        onRequestInputFocus?(window)
        _ = window.makeFirstResponder(self)
        action()
    }
}
