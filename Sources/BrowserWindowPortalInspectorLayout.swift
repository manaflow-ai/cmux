import AppKit
import CmuxAppKitSupportUI

extension WindowBrowserPortal {
    static func hasVisibleInspectorView(in root: NSView) -> Bool {
        var stack: [NSView] = [root]
        while let current = stack.popLast() {
            if cmuxIsWebInspectorObject(current),
               !current.isHidden,
               current.alphaValue > 0,
               current.frame.width > 1,
               current.frame.height > 1 {
                return true
            }
            stack.append(contentsOf: current.subviews)
        }
        return false
    }
}

extension BrowserWindowPortalRegistry {
    private static var browserHostMountObserver: NSObjectProtocol?

    static func installBrowserHostMountObserverIfNeeded() {
        guard browserHostMountObserver == nil else { return }
        browserHostMountObserver = NotificationCenter.default.addObserver(
            forName: .windowContentOverlayBrowserHostDidMount,
            object: nil,
            queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                scheduleExternalGeometrySynchronize(for: window)
            }
        }
    }
}
