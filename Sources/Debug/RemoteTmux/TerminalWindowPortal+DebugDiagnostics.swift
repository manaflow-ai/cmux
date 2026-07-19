#if DEBUG
import AppKit

extension WindowTerminalPortal {
    /// Hosted views whose frame has drifted from their anchor's — the
    /// definitive "terminal drawn over chrome" detector: the portal paints
    /// hosted content above SwiftUI at the anchor's rect, so any divergence
    /// means content is covering chrome or a neighboring pane.
    func misplacedHostedViewDescriptions(hostedViewIDs: Set<ObjectIdentifier>? = nil) -> [String] {
        var descriptions: [String] = []
        for (hostedViewID, entry) in entriesByHostedId {
            if let hostedViewIDs, !hostedViewIDs.contains(hostedViewID) { continue }
            guard let hosted = entry.hostedView,
                  let anchor = entry.anchorView,
                  entry.visibleInUI,
                  !hosted.isHidden,
                  hosted.superview != nil,
                  anchor.window != nil else { continue }
            let expected = expectedHostedFrameInHost(for: anchor)
            let actual = hosted.frame
            if abs(expected.origin.x - actual.origin.x) > 1.5
                || abs(expected.origin.y - actual.origin.y) > 1.5
                || abs(expected.width - actual.width) > 1.5
                || abs(expected.height - actual.height) > 1.5 {
                descriptions.append(
                    "hosted=\(portalDebugToken(hosted))"
                        + " actual=\(portalDebugFrame(actual))"
                        + " anchor=\(portalDebugFrame(expected))"
                )
            }
        }
        return descriptions
    }

    /// Logs the widest anchor's superview chain so the first view wider than
    /// its window identifies a content-derived ideal on the SwiftUI side.
    func debugLogWidestAnchorChain(hostedViewIDs: Set<ObjectIdentifier>? = nil) {
        let anchors: [NSView] = entriesByHostedId.compactMap { element -> NSView? in
            let (hostedViewID, entry) = element
            if let hostedViewIDs, !hostedViewIDs.contains(hostedViewID) { return nil }
            return entry.anchorView
        }
            .filter { $0.window != nil }
        guard let anchor = anchors.max(by: { $0.bounds.width < $1.bounds.width }) else { return }
        var node: NSView? = anchor
        var depth = 0
        while let current = node, depth < 60 {
            cmuxDebugLog(
                "portal.anchor.chain [\(depth)] \(String(describing: type(of: current)))"
                    + " w=\(Int(current.frame.width))"
            )
            node = current.superview
            depth += 1
        }
    }
}

extension TerminalWindowPortalRegistry {
    static func misplacedHostedViewDescriptions(
        for window: NSWindow,
        hostedViewIDs: Set<ObjectIdentifier>? = nil
    ) -> [String] {
        let portal = portalsByWindowId[ObjectIdentifier(window)]
        let descriptions = portal?.misplacedHostedViewDescriptions(
            hostedViewIDs: hostedViewIDs
        ) ?? []
        if !descriptions.isEmpty {
            portal?.debugLogWidestAnchorChain(hostedViewIDs: hostedViewIDs)
        }
        return descriptions
    }
}

extension WindowTerminalPortal {
    struct DebugStats {
        let windowNumber: Int
        let entryCount: Int
        let hostSubviewCount: Int
        let terminalSubviewCount: Int
        let mappedTerminalSubviewCount: Int
        let orphanTerminalSubviewCount: Int
        let visibleOrphanTerminalSubviewCount: Int
        let staleEntryCount: Int
        let visibleInvalidAnchorEntryCount: Int
    }

    func debugStats() -> DebugStats {
        let terminalSubviews = hostView.subviews.compactMap { $0 as? GhosttySurfaceScrollView }
        var mappedTerminalSubviewCount = 0
        var orphanTerminalSubviewCount = 0
        var visibleOrphanTerminalSubviewCount = 0
        var visibleInvalidAnchorEntryCount = 0

        for hostedView in terminalSubviews {
            let hostedId = ObjectIdentifier(hostedView)
            if entriesByHostedId[hostedId] != nil {
                mappedTerminalSubviewCount += 1
            } else {
                orphanTerminalSubviewCount += 1
                if hostedView.window != nil,
                   !hostedView.isHidden,
                   hostedView.frame.width > Self.tinyHideThreshold,
                   hostedView.frame.height > Self.tinyHideThreshold {
                    visibleOrphanTerminalSubviewCount += 1
                }
            }
        }

        for entry in entriesByHostedId.values where entry.visibleInUI {
            guard let anchor = entry.anchorView else {
                visibleInvalidAnchorEntryCount += 1
                continue
            }
            let anchorInvalidForCurrentHost =
                anchor.window !== window ||
                anchor.superview == nil ||
                (installedReferenceView.map { !anchor.isDescendant(of: $0) } ?? false)
            if anchorInvalidForCurrentHost {
                visibleInvalidAnchorEntryCount += 1
            }
        }

        let staleEntryCount = entriesByHostedId.values.reduce(0) { partialResult, entry in
            guard let hostedView = entry.hostedView else { return partialResult + 1 }
            return hostedView.superview === hostView ? partialResult : partialResult + 1
        }

        return DebugStats(
            windowNumber: window?.windowNumber ?? -1,
            entryCount: entriesByHostedId.count,
            hostSubviewCount: hostView.subviews.count,
            terminalSubviewCount: terminalSubviews.count,
            mappedTerminalSubviewCount: mappedTerminalSubviewCount,
            orphanTerminalSubviewCount: orphanTerminalSubviewCount,
            visibleOrphanTerminalSubviewCount: visibleOrphanTerminalSubviewCount,
            staleEntryCount: staleEntryCount,
            visibleInvalidAnchorEntryCount: visibleInvalidAnchorEntryCount
        )
    }

    func debugEntryCount() -> Int {
        entriesByHostedId.count
    }

    func debugHostedSubviewCount() -> Int {
        hostView.subviews.count
    }
}

extension TerminalWindowPortalRegistry {
    static func debugPortalCount() -> Int {
        portalsByWindowId.count
    }

    static func debugPortalStats() -> [String: Any] {
        var portals: [[String: Any]] = []
        var totals: [String: Int] = [
            "entry_count": 0,
            "host_subview_count": 0,
            "terminal_subview_count": 0,
            "mapped_terminal_subview_count": 0,
            "orphan_terminal_subview_count": 0,
            "visible_orphan_terminal_subview_count": 0,
            "stale_entry_count": 0,
            "visible_invalid_anchor_entry_count": 0,
            "mapped_hosted_count": 0,
        ]

        for (windowId, portal) in portalsByWindowId {
            let stats = portal.debugStats()
            let mappedHostedCount = hostedToWindowId.values.reduce(0) { partialResult, mappedWindowId in
                partialResult + (mappedWindowId == windowId ? 1 : 0)
            }
            let integrityOK =
                stats.orphanTerminalSubviewCount == 0 &&
                stats.visibleOrphanTerminalSubviewCount == 0 &&
                stats.staleEntryCount == 0 &&
                stats.visibleInvalidAnchorEntryCount == 0 &&
                mappedHostedCount == stats.entryCount

            portals.append([
                "window_number": stats.windowNumber,
                "entry_count": stats.entryCount,
                "mapped_hosted_count": mappedHostedCount,
                "host_subview_count": stats.hostSubviewCount,
                "terminal_subview_count": stats.terminalSubviewCount,
                "mapped_terminal_subview_count": stats.mappedTerminalSubviewCount,
                "orphan_terminal_subview_count": stats.orphanTerminalSubviewCount,
                "visible_orphan_terminal_subview_count": stats.visibleOrphanTerminalSubviewCount,
                "stale_entry_count": stats.staleEntryCount,
                "visible_invalid_anchor_entry_count": stats.visibleInvalidAnchorEntryCount,
                "integrity_ok": integrityOK,
            ])

            totals["entry_count", default: 0] += stats.entryCount
            totals["host_subview_count", default: 0] += stats.hostSubviewCount
            totals["terminal_subview_count", default: 0] += stats.terminalSubviewCount
            totals["mapped_terminal_subview_count", default: 0] += stats.mappedTerminalSubviewCount
            totals["orphan_terminal_subview_count", default: 0] += stats.orphanTerminalSubviewCount
            totals["visible_orphan_terminal_subview_count", default: 0] += stats.visibleOrphanTerminalSubviewCount
            totals["stale_entry_count", default: 0] += stats.staleEntryCount
            totals["visible_invalid_anchor_entry_count", default: 0] += stats.visibleInvalidAnchorEntryCount
            totals["mapped_hosted_count", default: 0] += mappedHostedCount
        }

        portals.sort {
            let lhs = ($0["window_number"] as? Int) ?? Int.min
            let rhs = ($1["window_number"] as? Int) ?? Int.min
            return lhs < rhs
        }

        return [
            "portal_count": portals.count,
            "hosted_mapping_count": hostedToWindowId.count,
            "guarded_bind_blocked_count": blockedBindCount,
            "guarded_bind_blocked_reasons": blockedBindReasons,
            "portals": portals,
            "totals": totals,
        ]
    }
}

#endif
