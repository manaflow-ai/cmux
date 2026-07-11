import AppKit

/// Tracks the sidebar's on-screen region in window coordinates so the window-level
/// file-drop overlay can tell when a Finder drop point is over the sidebar. Mirrors
/// MinimalModeTitlebarControlHitRegionRegistry (WindowDragHandleView.swift).
@MainActor
enum SidebarDropRegionRegistry {
    private final class WeakBox {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private static var probes: [ObjectIdentifier: WeakBox] = [:]

    static func register(_ view: NSView) {
        probes[ObjectIdentifier(view)] = WeakBox(view)
    }

    static func unregister(_ view: NSView) {
        probes.removeValue(forKey: ObjectIdentifier(view))
    }

    static func containsWindowPoint(_ windowPoint: NSPoint, in window: NSWindow) -> Bool {
        for (_, box) in probes {
            guard let view = box.view,
                  view.window === window,
                  !view.isHiddenOrHasHiddenAncestor,
                  view.alphaValue > 0 else { continue }
            let frameInWindow = view.convert(view.bounds, to: nil)
            if frameInWindow.contains(windowPoint) { return true }
        }
        return false
    }
}
