import AppKit
import SwiftUI

/// A SwiftUI-owned AppKit view spanning the workspace-list viewport.
///
/// The host gives the pointer owner a stable window and coordinate source
/// without discovering or mutating SwiftUI's private scroll-view hierarchy.
@MainActor
struct SidebarPointerEventHost: NSViewRepresentable {
    let onResolve: @MainActor (NSView) -> Void
    let onDismantle: @MainActor (NSView) -> Void

    init(
        _ onResolve: @escaping @MainActor (NSView) -> Void,
        onDismantle: @escaping @MainActor (NSView) -> Void
    ) {
        self.onResolve = onResolve
        self.onDismantle = onDismantle
    }

    func makeNSView(context: Context) -> SidebarPointerEventHostView {
        let view = SidebarPointerEventHostView()
        view.onResolve = onResolve
        view.onDismantle = onDismantle
        return view
    }

    func updateNSView(_ nsView: SidebarPointerEventHostView, context: Context) {
        nsView.onResolve = onResolve
        nsView.onDismantle = onDismantle
        nsView.resolve()
    }

    static func dismantleNSView(_ nsView: SidebarPointerEventHostView, coordinator: ()) {
        nsView.onDismantle?(nsView)
        nsView.onResolve = nil
        nsView.onDismantle = nil
    }
}

@MainActor
final class SidebarPointerEventHostView: NSView {
    var onResolve: (@MainActor (NSView) -> Void)?
    var onDismantle: (@MainActor (NSView) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        resolve()
    }

    func resolve() {
        onResolve?(self)
    }
}
