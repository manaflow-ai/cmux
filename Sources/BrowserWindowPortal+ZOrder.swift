import AppKit

@MainActor
extension WindowBrowserPortal {
    func portalZPriority(of view: NSView) -> Int {
        for entry in entriesByWebViewId.values where entry.containerView === view {
            return entry.zPriority
        }
        return 0
    }

    func refreshPortalZOrder() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        hostView.sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let portal = Unmanaged<WindowBrowserPortal>.fromOpaque(context).takeUnretainedValue()
            let lhsPriority = portal.portalZPriority(of: lhs)
            let rhsPriority = portal.portalZPriority(of: rhs)
            if lhsPriority == rhsPriority { return .orderedSame }
            return lhsPriority < rhsPriority ? .orderedAscending : .orderedDescending
        }, context: context)
    }
}
