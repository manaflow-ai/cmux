public import AppKit
public import SwiftUI

/// A SwiftUI-backed invisible view that reports its laid-out `NSView` through `onResolve`,
/// used to anchor titlebar-control menus and popovers (e.g. the browser extension control)
/// to a settled window-space frame.
public struct TitlebarControlAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    public init(onResolve: @escaping (NSView) -> Void) {
        self.onResolve = onResolve
    }

    public func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            onResolve(view)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
