public import AppKit
public import SwiftUI

/// A SwiftUI-backed invisible view that registers its laid-out `NSView` with
/// `NotificationsAnchorRegistry` and reports it through `onResolve`, so the notifications
/// popover can attach to the notifications bell control.
public struct NotificationsAnchorView: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    public init(onResolve: @escaping (NSView) -> Void) {
        self.onResolve = onResolve
    }

    public func makeNSView(context: Context) -> NSView {
        let view = AnchorNSView()
        view.onLayout = { [weak view] in
            guard let view else { return }
            NotificationsAnchorRegistry.shared.register(view)
            onResolve(view)
        }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}
}
