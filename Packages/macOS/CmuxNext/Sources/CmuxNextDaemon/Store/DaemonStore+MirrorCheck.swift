import Foundation

/// Debug-build check of the mirror's single-writer rule (OWNERSHIP-PRINCIPLES.md:
/// "a client keeps a confirmed mirror written only by owner events, plus one
/// ordered log of pending typed intents").
///
/// The allowed writers record the layout's fingerprint (a hash of the
/// workspace order, screens, panes and the tabs in each) when they finish: daemon event and
/// snapshot apply with the intent overlay (`withOverlayLifted`), a new
/// intent, and the legacy optimistic patches that have not moved to the
/// intent log yet (DaemonStore+Optimistic.swift). The next allowed writer
/// compares before it writes; a difference means something else wrote the
/// records. It also checks that the overlay never changes the set of tabs
/// (invariant 1). Violations are logged as faults and kept in
/// `mirrorViolations`, which `debug.desync` reports. Release builds skip
/// all of it.
extension DaemonStore {
    static let mirrorViolationLimit = 32

    func verifyMirrorUnchanged(before writer: String) {
        #if DEBUG
        guard let recorded = mirrorFingerprint, layoutFingerprint() != recorded else { return }
        let tabs = workspaces.flatMap(\.screens).flatMap(\.panes).map(\.tabs.count).reduce(0, +)
        reportMirrorViolation("mirror records written outside daemon apply and the intent overlay "
            + "(found before \(writer); \(workspaces.count) workspaces, \(tabs) tabs now)")
        #endif
    }

    func recordMirror() {
        #if DEBUG
        mirrorFingerprint = layoutFingerprint()
        #endif
    }

    /// The tabs of the records, sorted (debug builds; empty otherwise).
    func debugTabCensus() -> [String] {
        #if DEBUG
        guard !intentLog.isEmpty else { return [] }
        return workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id).sorted()
        #else
        return []
        #endif
    }

    /// Invariant 1 for the overlay: applying the intents kept every tab.
    func checkOverlayConservation(confirmed: [String]) {
        #if DEBUG
        guard !intentLog.isEmpty else { return }
        let visible = workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id).sorted()
        guard visible != confirmed else { return }
        reportMirrorViolation("intent overlay changed the tabs: confirmed \(confirmed.count), visible \(visible.count)")
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

    /// A hash of the workspace order, screens, panes and each pane's tabs in
    /// order (no allocation; it runs twice per event batch in debug builds).
    private func layoutFingerprint() -> Int {
        var hasher = Hasher()
        for workspace in workspaces {
            hasher.combine(0 as UInt8)
            hasher.combine(workspace.id)
            for screen in workspace.screens {
                hasher.combine(1 as UInt8)
                hasher.combine(screen.id)
                for pane in screen.panes {
                    hasher.combine(2 as UInt8)
                    hasher.combine(pane.id)
                    for tab in pane.tabs { hasher.combine(tab.id) }
                }
            }
        }
        return hasher.finalize()
    }
}
