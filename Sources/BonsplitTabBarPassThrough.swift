import AppKit
import Bonsplit

/// Shared helpers for portal hosts that must defer to the minimal-mode
/// Bonsplit tab strip rendered underneath them.
enum BonsplitTabBarPassThrough {
    static func isPassThroughPointerEvent(_ eventType: NSEvent.EventType?) -> Bool {
        switch eventType {
        case nil:
            // Unit tests can call hitTest directly without an active AppKit event.
            return true
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged,
             .mouseMoved, .mouseEntered,
             .mouseExited, .cursorUpdate,
             .appKitDefined, .applicationDefined, .systemDefined, .periodic:
            return true
        default:
            return false
        }
    }

    static func titlebarInteractionBandMinY(in window: NSWindow) -> CGFloat {
        let nativeTitlebarHeight = window.frame.height - window.contentLayoutRect.height
        let customTitlebarBandHeight = max(28, min(72, nativeTitlebarHeight))
        return window.contentLayoutRect.maxY - customTitlebarBandHeight - 0.5
    }

    // The minimal-mode tab strip lives just under the titlebar. Anything more
    // than this many points below the content top can't overlap it, so we skip
    // the recursive subtree scan on the pointer-event hot path.
    private static let tabStripScanBandHeight: CGFloat = 200

    static func shouldPassThroughToPaneTabBar(
        windowPoint: NSPoint,
        below portalHost: NSView
    ) -> (result: Bool, registryHit: Bool) {
        let registryHit = portalHost.window.map {
            BonsplitTabBarHitRegionRegistry.containsWindowPoint(windowPoint, in: $0)
        } ?? false
        if registryHit {
            return (true, true)
        }

        // High-frequency pointer events (mouseMoved/cursorUpdate) flow through
        // here on every hover; cap the recursive view-tree walk to the top
        // band where the tab strip can actually live.
        if let window = portalHost.window {
            let scanFloor = window.contentLayoutRect.maxY - tabStripScanBandHeight
            if windowPoint.y < scanFloor {
                return (false, false)
            }
        }

        let fallbackHit = hasUnderlyingBonsplitTabBarBackground(
            at: windowPoint,
            below: portalHost
        )
        return (fallbackHit, false)
    }

    static func passThroughDecision(
        at point: NSPoint,
        in portalHost: NSView,
        eventType: NSEvent.EventType?
    ) -> (windowPoint: NSPoint, result: Bool, registryHit: Bool)? {
        guard isPassThroughPointerEvent(eventType) else { return nil }
        let windowPoint = portalHost.convert(point, to: nil)
        let decision = shouldPassThroughToPaneTabBar(windowPoint: windowPoint, below: portalHost)
        return (windowPoint, decision.result, decision.registryHit)
    }

    static func hasBonsplitTabBarBackground(at windowPoint: NSPoint, in view: NSView) -> Bool {
        guard !view.isHidden, view.alphaValue > 0 else { return false }

        // NSView subviews are not clipped to parent bounds by default, and the
        // minimal tab strip can render outside its immediate container.
        let className = NSStringFromClass(type(of: view))
        if className.contains("TabBarBackgroundNSView") {
            let pointInView = view.convert(windowPoint, from: nil)
            if view.bounds.contains(pointInView) {
                return true
            }
        }

        for subview in view.subviews.reversed() {
            if hasBonsplitTabBarBackground(at: windowPoint, in: subview) {
                return true
            }
        }
        return false
    }

    static func hasUnderlyingBonsplitTabBarBackground(
        at windowPoint: NSPoint,
        below portalHost: NSView
    ) -> Bool {
        // Only walk siblings rendered below the host. Falling back to the full
        // window content tree when the host has no superview would risk a
        // false-positive pass-through against a tab bar painted above an
        // unparented host.
        guard let container = portalHost.superview,
              let hostIndex = container.subviews.firstIndex(of: portalHost) else {
            return false
        }
        for sibling in container.subviews[..<hostIndex].reversed() {
            guard !sibling.isHidden, sibling.alphaValue > 0 else { continue }
            if hasBonsplitTabBarBackground(at: windowPoint, in: sibling) {
                return true
            }
        }
        return false
    }
}
