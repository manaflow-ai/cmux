import AppKit
public import SwiftUI

/// Invisible `NSViewRepresentable` that reports left-mouse-down events landing
/// inside its frame, used to give the file-preview panel pointer-driven focus
/// without intercepting the click (the backing view hit-tests to `nil`, so the
/// event also reaches the underlying preview content).
///
/// Mirrors ``MiddleClickCapture``: a thin representable over a single backing
/// `NSView` wired to one closure seam, with no reference to the caller's panel
/// model. The actual `NSEvent` local monitoring lives in
/// ``FilePreviewPointerObserverView``.
public struct FilePreviewPointerObserver: NSViewRepresentable {
    /// Invoked when a left-mouse-down lands inside the observer's frame.
    public let onPointerDown: () -> Void

    /// Creates a pointer-down observer.
    /// - Parameter onPointerDown: Invoked (deferred to the main queue) when a
    ///   left-mouse-down lands inside the observer's frame.
    public init(onPointerDown: @escaping () -> Void) {
        self.onPointerDown = onPointerDown
    }

    public func makeNSView(context: Context) -> FilePreviewPointerObserverView {
        let view = FilePreviewPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    public func updateNSView(_ nsView: FilePreviewPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}
