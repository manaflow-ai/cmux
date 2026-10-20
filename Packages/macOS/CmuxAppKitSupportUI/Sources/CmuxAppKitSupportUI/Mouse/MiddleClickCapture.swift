import AppKit
public import SwiftUI

/// A transparent overlay that intercepts only middle-mouse clicks, letting left-click
/// selection and right-click context menus hit-test through to the underlying view tree.
public struct MiddleClickCapture: NSViewRepresentable {
    public let onMiddleClick: () -> Void

    /// Creates a middle-click capture overlay.
    /// - Parameter onMiddleClick: Invoked when a middle (button 2) click lands on the overlay.
    public init(onMiddleClick: @escaping () -> Void) {
        self.onMiddleClick = onMiddleClick
    }

    public func makeNSView(context: Context) -> MiddleClickCaptureView {
        let view = MiddleClickCaptureView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    public func updateNSView(_ nsView: MiddleClickCaptureView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }
}
