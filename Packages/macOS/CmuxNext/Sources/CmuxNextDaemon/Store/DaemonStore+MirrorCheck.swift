import Foundation

/// Debug-build check of the mirror's single-writer rule (OWNERSHIP-PRINCIPLES.md:
/// "a client keeps a confirmed mirror written only by owner events, plus one
/// ordered log of pending typed intents").
///
/// The allowed writers record the mirror's fingerprint (a hash of the
/// workspace order, names and groups, screens, panes, the tabs in each with
/// their names and pins, and group collapse state) when they finish: daemon
/// event and snapshot apply with the intent overlay (`withOverlayLifted`)
/// and a new intent. The next allowed writer
/// compares before it writes; a difference means something else wrote the
/// records. It also checks that the overlay never changes the set of tabs
/// (invariant 1). Violations are logged as faults and kept in
/// `mirrorViolations`, which `debug.desync` reports. Release builds skip
/// all of it.
extension DaemonStore {
    static let mirrorViolationLimit = 32

    /// The fingerprint walks the whole tree, so it is taken at most once
    /// per `mirrorCheckInterval` (a drag or status ticks apply batches every
    /// frame): an allowed writer that ends within the interval of the last
    /// recording clears it, and the next writer checks nothing. A write
    /// outside the allowed writers is still found at the next recorded window.
    static let mirrorCheckInterval: Duration = .seconds(1)

    func verifyMirrorUnchanged(before writer: String) {
        #if DEBUG
        guard let recorded = mirrorFingerprint, layoutFingerprint() != recorded else { return }
        reportMirrorViolation("mirror records written outside daemon apply and the intent overlay "
            + "(found before \(writer); \(workspaces.count) workspaces, \(index.tabsBySurface.count) tabs now)")
        #endif
    }

    func recordMirror() {
        #if DEBUG
        let now = ContinuousClock.now
        if let last = mirrorFingerprintTakenAt, now - last < Self.mirrorCheckInterval {
            mirrorFingerprint = nil
            return
        }
        mirrorFingerprintTakenAt = now
        mirrorFingerprint = layoutFingerprint()
        verifyUnreadTotals()
        #endif
    }

    /// The number of confirmed (not provisional) tabs, from the index
    /// (debug builds; 0 otherwise).
    func debugTabCensus() -> Int {
        #if DEBUG
        guard !intentLog.isEmpty else { return 0 }
        return index.tabsByID.count - index.provisionalTabCount
        #else
        return 0
        #endif
    }

    /// Invariant 1 for the overlay: applying the intents kept every tab
    /// (a create intent adds only its provisional tab, which is not counted).
    func checkOverlayConservation(confirmed: Int) {
        #if DEBUG
        guard !intentLog.isEmpty else { return }
        let visible = index.tabsByID.count - index.provisionalTabCount + CancelledCreation.hiddenTabs(in: intentLog)
        guard visible != confirmed else { return }
        reportMirrorViolation("intent overlay changed the tabs: confirmed \(confirmed), visible \(visible)")
        #endif
    }

    func reportMirrorViolation(_ detail: String) {
        mirrorViolations.append(detail)
        if mirrorViolations.count > Self.mirrorViolationLimit {
            mirrorViolations.removeFirst(mirrorViolations.count - Self.mirrorViolationLimit)
        }
        #if DEBUG
        logger.fault("mirror: \(detail, privacy: .public)")
        #else
        logger.error("mirror: \(detail, privacy: .public)")
        #endif
        onMirrorViolation?(detail)
    }

    /// A hash of every field an intent writes: the workspace order, names
    /// and groups, screens, panes, each pane's tabs in order with their names
    /// and pins, and workspace and tab group collapse state (no allocation;
    /// at most once per `mirrorCheckInterval`, debug builds only).
    private func layoutFingerprint() -> Int {
        var hasher = Hasher()
        for group in groups {
            hasher.combine(3 as UInt8)
            hasher.combine(group.id)
            hasher.combine(group.collapsed)
        }
        for workspace in workspaces {
            hasher.combine(0 as UInt8)
            hasher.combine(workspace.id)
            hasher.combine(workspace.name)
            hasher.combine(workspace.group)
            for screen in workspace.screens {
                hasher.combine(1 as UInt8)
                hasher.combine(screen.id)
                for pane in screen.panes {
                    hasher.combine(2 as UInt8)
                    hasher.combine(pane.id)
                    for tab in pane.tabs {
                        hasher.combine(tab.id)
                        hasher.combine(tab.name)
                        hasher.combine(tab.pinned)
                    }
                    for group in pane.tabGroups {
                        hasher.combine(4 as UInt8)
                        hasher.combine(group.id)
                        hasher.combine(group.collapsed)
                    }
                }
            }
        }
        return hasher.finalize()
    }
}
