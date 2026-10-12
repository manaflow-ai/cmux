import AppKit
public import SwiftUI

public extension View {
    /// The shared thin scroller (SCROLLBARS-THIN) for a SwiftUI `ScrollView`: on macOS it is an
    /// NSScrollView that follows the "Show scroll bars" setting, a gray track for "Always". Put it
    /// on the scroll view's content (`ScrollView { rows.thinScrollers() }`): a zero-size probe in
    /// the content hands its enclosing scroll view to ``SystemScrollers/follow(_:)``.
    func thinScrollers() -> some View { background(ThinScrollerProbe()) }
}

private struct ThinScrollerProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollView = enclosingScrollView { SystemScrollers.follow(scrollView) }
        }

        // Never takes a click meant for the rows.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
