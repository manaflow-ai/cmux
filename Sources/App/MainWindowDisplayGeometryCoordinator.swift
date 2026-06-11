import AppKit

@MainActor
final class MainWindowDisplayGeometryCoordinator {
    typealias DisplayGeometry = AppDelegate.SessionDisplayGeometry

    struct LiveWindowGeometry {
        let windowId: UUID
        let frame: CGRect?
        let displayID: UInt32?
        let display: SessionDisplaySnapshot?
    }

    struct CurrentGeometry {
        let connectedDisplayIDs: Set<UInt32>
        let availableDisplays: [DisplayGeometry]
        let fallbackDisplay: DisplayGeometry?
        let windows: [LiveWindowGeometry]

        func window(for windowId: UUID) -> LiveWindowGeometry? {
            windows.first { $0.windowId == windowId }
        }
    }

    struct GeometrySnapshot {
        let frame: SessionRectSnapshot?
        let display: SessionDisplaySnapshot?
    }

    struct RestoreRequest {
        let windowId: UUID
        let displayID: UInt32
        let frame: CGRect
    }

    enum TransitionReason: Equatable, Sendable {
        case sleepWake
        case displayReconfiguration
    }

    enum TransitionSource: String {
        case workspaceSessionDidResignActive = "workspace.sessionDidResignActive"
        case workspaceScreensDidSleep = "workspace.screensDidSleep"
        case applicationDidChangeScreenParameters = "app.didChangeScreenParameters"
    }

    enum ChangeSource: String {
        case applicationDidChangeScreenParameters = "app.didChangeScreenParameters"
        case workspaceDidWake = "workspace.didWake"
        case workspaceScreensDidWake = "workspace.screensDidWake"
        case workspaceSessionDidBecomeActive = "workspace.sessionDidBecomeActive"

        var endsVolatilePhase: Bool {
            switch self {
            case .workspaceDidWake, .workspaceScreensDidWake, .workspaceSessionDidBecomeActive:
                return true
            case .applicationDidChangeScreenParameters:
                return false
            }
        }

        var keepsSleepWakeRecoveryOpen: Bool {
            self == .workspaceScreensDidWake
        }

        var usesSleepWakeShrinkProtection: Bool {
            switch self {
            case .workspaceDidWake, .workspaceScreensDidWake, .workspaceSessionDidBecomeActive:
                return true
            case .applicationDidChangeScreenParameters:
                return false
            }
        }
    }

    private struct SavedDisplayWindowFrame {
        let windowId: UUID
        let frame: SessionRectSnapshot
        let display: SessionDisplaySnapshot
    }

    private enum Phase {
        case stable
        case volatile(TransitionReason)
        case sleepWakeRecovery
    }

    private var lastKnownDisplayIDs: Set<UInt32> = []
    private var savedDisplayWindowFrames: [UInt32: [SavedDisplayWindowFrame]] = [:]
    private var phase: Phase = .stable
    private(set) var isApplyingCachedWindowGeometry = false

    private var cachedFrameProtectionReason: TransitionReason? {
        switch phase {
        case .stable:
            return nil
        case .volatile(let reason):
            return reason
        case .sleepWakeRecovery:
            return .sleepWake
        }
    }

    private var isSleepWakeRecovery: Bool {
        if case .sleepWakeRecovery = phase {
            return true
        }
        return false
    }

    func prime(current: CurrentGeometry) {
        lastKnownDisplayIDs = current.connectedDisplayIDs
        updateSavedWindowFrames(current: current)
    }

    func recordCurrentGeometry(current: CurrentGeometry) {
        updateSavedWindowFrames(current: current)
    }

    func beginTransition(
        source: TransitionSource,
        reason: TransitionReason,
        current: CurrentGeometry
    ) {
        if case .volatile(let currentReason) = phase {
            if currentReason == .displayReconfiguration && reason == .sleepWake {
                phase = .volatile(reason)
            }
            return
        }

        phase = .volatile(reason)
        updateSavedWindowFrames(current: current)

#if DEBUG
        cmuxDebugLog("window.geometry.transition.begin source=\(source.rawValue)")
#endif
    }

    func recordUserWindowChange(
        liveWindow: LiveWindowGeometry,
        current: CurrentGeometry
    ) {
        guard !isApplyingCachedWindowGeometry else { return }

        if cachedFrameProtectionReason != nil,
           let entry = savedDisplayWindowFrame(
               forWindowId: liveWindow.windowId,
               liveDisplayID: liveWindow.displayID,
               connectedDisplayIDs: current.connectedDisplayIDs
           ),
           shouldKeepCachedFrameDuringDisplayTransition(
               entry,
               liveWindow: liveWindow,
               displays: current.availableDisplays
           ) {
            return
        }

        if cachedFrameProtectionReason != nil,
           let displayID = liveWindow.displayID,
           let entry = savedDisplayWindowFrames[displayID]?.first(where: { $0.windowId == liveWindow.windowId }),
           shouldRestoreCachedFrameForCurrentDisplay(
               entry,
               liveWindow: liveWindow,
               displays: current.availableDisplays
           ) {
            return
        }

        updateSavedWindowFrames(
            current: current,
            invalidateDisconnectedDisplayFramesForUpdatedWindows: true
        )
    }

    func restoreRequests(
        source: ChangeSource,
        current: CurrentGeometry
    ) -> [RestoreRequest] {
        let currentIDs = current.connectedDisplayIDs
        let appearedIDs = currentIDs.subtracting(lastKnownDisplayIDs)
        lastKnownDisplayIDs = currentIDs

        var requestsByWindowID: [UUID: RestoreRequest] = [:]

        func enqueueRestore(_ entry: SavedDisplayWindowFrame, displayID: UInt32) {
            guard let liveWindow = current.window(for: entry.windowId),
                  let liveFrame = liveWindow.frame,
                  let restoredFrame = AppDelegate.resolvedWindowFrame(
                      from: entry.frame,
                      display: entry.display,
                      availableDisplays: current.availableDisplays,
                      fallbackDisplay: current.fallbackDisplay
                  ),
                  !Self.rectApproximatelyEqual(liveFrame, restoredFrame) else {
                return
            }

            requestsByWindowID[entry.windowId] = RestoreRequest(
                windowId: entry.windowId,
                displayID: displayID,
                frame: restoredFrame
            )
        }

        for displayID in appearedIDs {
            for entry in savedDisplayWindowFrames[displayID] ?? [] {
                enqueueRestore(entry, displayID: displayID)
            }
        }

        for liveWindow in current.windows {
            let protectionReason = cachedFrameProtectionReason
                ?? (source.usesSleepWakeShrinkProtection ? .sleepWake : nil)
            let shrinkOnlyProtection = cachedFrameProtectionReason == nil && source.usesSleepWakeShrinkProtection
            guard let liveDisplayID = liveWindow.displayID,
                  let entry = savedDisplayWindowFrame(
                      forWindowId: liveWindow.windowId,
                      liveDisplayID: liveDisplayID,
                      connectedDisplayIDs: current.connectedDisplayIDs
                  ) else {
                continue
            }

            let restoreDisplayID = entry.display.displayID ?? liveDisplayID
            let shouldRestoreCachedFrame = shouldRestoreCachedFrameForCurrentDisplay(
                entry,
                liveWindow: liveWindow,
                displays: current.availableDisplays
            ) || (currentIDs.contains(restoreDisplayID)
                && shouldKeepCachedFrameDuringDisplayTransition(
                    entry,
                    liveWindow: liveWindow,
                    displays: current.availableDisplays,
                    reason: protectionReason,
                    shrinkOnly: shrinkOnlyProtection
                ))
            guard shouldRestoreCachedFrame else { continue }
            enqueueRestore(entry, displayID: restoreDisplayID)
        }

        return current.windows.compactMap { requestsByWindowID[$0.windowId] }
    }

    func withApplyingCachedGeometry(_ body: () -> Void) {
        isApplyingCachedWindowGeometry = true
        defer { isApplyingCachedWindowGeometry = false }
        body()
    }

    func recordAppliedRestore(
        windowId: UUID,
        displayID: UInt32,
        frame: SessionRectSnapshot,
        display: SessionDisplaySnapshot?
    ) {
        guard let display else { return }
        let actualDisplayID = display.displayID ?? displayID
        removeWindowFrames(forWindowId: windowId)
        var bucket = savedDisplayWindowFrames[actualDisplayID] ?? []
        bucket.append(SavedDisplayWindowFrame(windowId: windowId, frame: frame, display: display))
        savedDisplayWindowFrames[actualDisplayID] = bucket
    }

    func finishDisplayGeometryChange(
        source: ChangeSource,
        current: CurrentGeometry,
        restoredWindowIDs: Set<UUID>
    ) {
        updateSavedWindowFrames(current: current, excluding: restoredWindowIDs)
        if source.keepsSleepWakeRecoveryOpen {
            phase = .sleepWakeRecovery
        } else if source.endsVolatilePhase || !hasCachedFrameProtectionGeometry(current: current) {
            phase = .stable
        }
    }

    func removeWindowFrames(forWindowId windowId: UUID) {
        for (displayID, entries) in Array(savedDisplayWindowFrames) {
            let filtered = entries.filter { $0.windowId != windowId }
            if filtered.isEmpty {
                savedDisplayWindowFrames.removeValue(forKey: displayID)
            } else if filtered.count != entries.count {
                savedDisplayWindowFrames[displayID] = filtered
            }
        }
    }

    func snapshotGeometry(
        windowId: UUID,
        liveFrame: CGRect?,
        liveDisplayID: UInt32?,
        liveDisplay: SessionDisplaySnapshot?,
        current: CurrentGeometry
    ) -> GeometrySnapshot {
        if let cached = savedFrameForProtectedWindow(
            windowId: windowId,
            liveDisplayID: liveDisplayID,
            liveFrame: liveFrame,
            current: current
        ) {
            return GeometrySnapshot(frame: cached.frame, display: cached.display)
        }

        return GeometrySnapshot(
            frame: liveFrame.map { SessionRectSnapshot($0) },
            display: liveDisplay
        )
    }

    private func updateSavedWindowFrames(
        current: CurrentGeometry,
        excluding excludedWindowIDs: Set<UUID> = [],
        invalidateDisconnectedDisplayFramesForUpdatedWindows: Bool = false
    ) {
        for liveWindow in current.windows {
            guard !excludedWindowIDs.contains(liveWindow.windowId) else { continue }
            guard let displayID = liveWindow.displayID,
                  let frame = liveWindow.frame,
                  let display = liveWindow.display else {
                continue
            }
            if cachedFrameProtectionReason != nil,
               let entry = savedDisplayWindowFrame(
                   forWindowId: liveWindow.windowId,
                   liveDisplayID: displayID,
                   connectedDisplayIDs: current.connectedDisplayIDs
               ),
               shouldKeepCachedFrameDuringDisplayTransition(
                   entry,
                   liveWindow: liveWindow,
                   displays: current.availableDisplays
               ) {
                continue
            }

            for (otherDisplayID, entries) in Array(savedDisplayWindowFrames)
            where otherDisplayID != displayID
                && (current.connectedDisplayIDs.contains(otherDisplayID)
                    || invalidateDisconnectedDisplayFramesForUpdatedWindows) {
                let filtered = entries.filter { $0.windowId != liveWindow.windowId }
                if filtered.isEmpty {
                    savedDisplayWindowFrames.removeValue(forKey: otherDisplayID)
                } else if filtered.count != entries.count {
                    savedDisplayWindowFrames[otherDisplayID] = filtered
                }
            }

            let entry = SavedDisplayWindowFrame(
                windowId: liveWindow.windowId,
                frame: SessionRectSnapshot(frame),
                display: display
            )
            var entries = savedDisplayWindowFrames[displayID] ?? []
            entries.removeAll { $0.windowId == liveWindow.windowId }
            entries.append(entry)
            savedDisplayWindowFrames[displayID] = entries
        }
    }

    private func savedDisplayWindowFrame(
        forWindowId windowId: UUID,
        liveDisplayID: UInt32?,
        connectedDisplayIDs: Set<UInt32>
    ) -> SavedDisplayWindowFrame? {
        if cachedFrameProtectionReason != nil,
           let liveDisplayID {
            for (displayID, entries) in savedDisplayWindowFrames
            where displayID != liveDisplayID && connectedDisplayIDs.contains(displayID) {
                if let entry = entries.first(where: { $0.windowId == windowId }) {
                    return entry
                }
            }
        }

        if let liveDisplayID,
           let entry = savedDisplayWindowFrames[liveDisplayID]?.first(where: { $0.windowId == windowId }) {
            return entry
        }

        for (displayID, entries) in savedDisplayWindowFrames where !connectedDisplayIDs.contains(displayID) {
            if let entry = entries.first(where: { $0.windowId == windowId }) {
                return entry
            }
        }
        for (displayID, entries) in savedDisplayWindowFrames where displayID != liveDisplayID {
            if let entry = entries.first(where: { $0.windowId == windowId }) {
                return entry
            }
        }
        return nil
    }

    private func hasCachedFrameProtectionGeometry(current: CurrentGeometry) -> Bool {
        guard cachedFrameProtectionReason != nil else { return false }
        for liveWindow in current.windows {
            guard let entry = savedDisplayWindowFrame(
                forWindowId: liveWindow.windowId,
                liveDisplayID: liveWindow.displayID,
                connectedDisplayIDs: current.connectedDisplayIDs
            ),
            shouldKeepCachedFrameDuringDisplayTransition(
                entry,
                liveWindow: liveWindow,
                displays: current.availableDisplays
            ) else {
                continue
            }
            return true
        }
        return false
    }

    private func shouldRestoreCachedFrameForCurrentDisplay(
        _ entry: SavedDisplayWindowFrame,
        liveWindow: LiveWindowGeometry,
        displays: [DisplayGeometry]
    ) -> Bool {
        guard let liveDisplayID = liveWindow.displayID,
              let liveFrame = liveWindow.frame,
              let currentDisplay = displays.first(where: { $0.displayID == liveDisplayID }) else {
            return false
        }
        guard entry.display.displayID == liveDisplayID else { return false }
        guard let cachedFrame = entry.display.frame?.cgRect,
              let cachedVisibleFrame = entry.display.visibleFrame?.cgRect else {
            return false
        }
        let displayChanged = !Self.rectApproximatelyEqual(cachedFrame, currentDisplay.frame)
            || !Self.rectApproximatelyEqual(cachedVisibleFrame, currentDisplay.visibleFrame)
        guard displayChanged else { return false }

        let savedFrame = entry.frame.cgRect
        return liveFrame.width < savedFrame.width || liveFrame.height < savedFrame.height
    }

    private func shouldKeepCachedFrameDuringDisplayTransition(
        _ entry: SavedDisplayWindowFrame,
        liveWindow: LiveWindowGeometry,
        displays: [DisplayGeometry],
        reason suppliedReason: TransitionReason? = nil,
        shrinkOnly: Bool? = nil
    ) -> Bool {
        guard let liveFrame = liveWindow.frame,
              let reason = suppliedReason ?? cachedFrameProtectionReason else {
            return false
        }
        if shrinkOnly ?? isSleepWakeRecovery {
            return reason == .sleepWake && Self.liveFrameShrank(savedFrame: entry.frame.cgRect, liveFrame: liveFrame)
        }
        return Self.shouldUseCachedWindowFrameDuringDisplayTransition(
            savedFrame: entry.frame.cgRect,
            liveFrame: liveFrame,
            cachedDisplay: entry.display,
            liveDisplayID: liveWindow.displayID,
            displays: displays,
            reason: reason
        )
    }

    private func savedFrameForProtectedWindow(
        windowId: UUID,
        liveDisplayID: UInt32?,
        liveFrame: CGRect?,
        current: CurrentGeometry
    ) -> SavedDisplayWindowFrame? {
        guard cachedFrameProtectionReason != nil else {
            return nil
        }

        for (displayID, entries) in savedDisplayWindowFrames where !current.connectedDisplayIDs.contains(displayID) {
            if let entry = entries.first(where: { $0.windowId == windowId }) {
                return entry
            }
        }

        guard let liveDisplayID,
              let liveFrame,
              let entry = savedDisplayWindowFrames[liveDisplayID]?.first(where: { $0.windowId == windowId }) else {
            return nil
        }
        let liveWindow = LiveWindowGeometry(
            windowId: windowId,
            frame: liveFrame,
            displayID: liveDisplayID,
            display: nil
        )
        let shouldUseCachedFrame = shouldRestoreCachedFrameForCurrentDisplay(
            entry,
            liveWindow: liveWindow,
            displays: current.availableDisplays
        ) || shouldKeepCachedFrameDuringDisplayTransition(
            entry,
            liveWindow: liveWindow,
            displays: current.availableDisplays
        )
        guard shouldUseCachedFrame else {
            return nil
        }
        return entry
    }

    nonisolated static func shouldUseCachedWindowFrameDuringDisplayTransition(
        savedFrame: CGRect,
        liveFrame: CGRect,
        cachedDisplay: SessionDisplaySnapshot,
        liveDisplayID: UInt32?,
        displays: [DisplayGeometry],
        reason: TransitionReason
    ) -> Bool {
        if reason == .sleepWake && liveFrameShrank(savedFrame: savedFrame, liveFrame: liveFrame) {
            return true
        }

        guard let liveDisplayID,
              let cachedDisplayID = cachedDisplay.displayID else {
            return false
        }
        if cachedDisplayID != liveDisplayID {
            return true
        }

        guard let currentDisplay = displays.first(where: { $0.displayID == liveDisplayID }),
              let cachedFrame = cachedDisplay.frame?.cgRect,
              let cachedVisibleFrame = cachedDisplay.visibleFrame?.cgRect else {
            return false
        }
        let displayChanged = !rectApproximatelyEqual(cachedFrame, currentDisplay.frame)
            || !rectApproximatelyEqual(cachedVisibleFrame, currentDisplay.visibleFrame)
        return displayChanged && !rectApproximatelyEqual(liveFrame, savedFrame)
    }

    private nonisolated static func liveFrameShrank(savedFrame: CGRect, liveFrame: CGRect) -> Bool {
        liveFrame.width < savedFrame.width || liveFrame.height < savedFrame.height
    }

    private nonisolated static func rectApproximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let lhsStd = lhs.standardized
        let rhsStd = rhs.standardized
        return abs(lhsStd.origin.x - rhsStd.origin.x) <= tolerance
            && abs(lhsStd.origin.y - rhsStd.origin.y) <= tolerance
            && abs(lhsStd.size.width - rhsStd.size.width) <= tolerance
            && abs(lhsStd.size.height - rhsStd.size.height) <= tolerance
    }
}
