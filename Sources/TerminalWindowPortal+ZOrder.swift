import AppKit

@MainActor
extension WindowTerminalPortal {
    static var raisedPortalPriority: Int { 10_000 }

    var hasRaisedVisibleEntries: Bool {
        entriesByHostedId.values.contains { entry in
            entry.visibleInUI && entry.zPriority >= Self.raisedPortalPriority
        }
    }

    func ensureDividerOverlayOnTop() {
        if dividerOverlayView.superview !== hostView {
            dividerOverlayView.frame = hostView.bounds
            hostView.addSubview(dividerOverlayView, positioned: .above, relativeTo: nil)
        }
        if !Self.rectApproximatelyEqual(dividerOverlayView.frame, hostView.bounds) {
            dividerOverlayView.frame = hostView.bounds
        }
        dividerOverlayView.needsDisplay = true
        refreshPortalZOrder()
    }

    func portalZPriority(of view: NSView) -> Int {
        if view === dividerOverlayView { return Self.raisedPortalPriority - 1 }
        for entry in entriesByHostedId.values where entry.hostedView === view {
            return entry.zPriority
        }
        return 0
    }

    func refreshPortalZOrder() {
        guard portalZOrderNeedsRefresh() else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        hostView.sortSubviews({ lhs, rhs, context in
            guard let context else { return .orderedSame }
            let portal = Unmanaged<WindowTerminalPortal>.fromOpaque(context).takeUnretainedValue()
            let lhsPriority = portal.portalZPriority(of: lhs)
            let rhsPriority = portal.portalZPriority(of: rhs)
            if lhsPriority == rhsPriority { return .orderedSame }
            return lhsPriority < rhsPriority ? .orderedAscending : .orderedDescending
        }, context: context)
    }

    func portalZOrderNeedsRefresh() -> Bool {
        var previousPriority = Int.min
        for subview in hostView.subviews {
            let priority = portalZPriority(of: subview)
            if priority < previousPriority { return true }
            previousPriority = priority
        }
        return false
    }

    func refreshHostPlacementForRaisedEntries() {
        guard let container = installedContainerView,
              let browserHost = preferredBrowserHost(in: container),
              hostView.superview === container else { return }
        if hasRaisedVisibleEntries {
            if !Self.isView(hostView, above: browserHost, in: container) {
                container.addSubview(hostView, positioned: .above, relativeTo: browserHost)
            }
        } else if !Self.isView(browserHost, above: hostView, in: container) {
            container.addSubview(hostView, positioned: .below, relativeTo: browserHost)
        }
    }
}
