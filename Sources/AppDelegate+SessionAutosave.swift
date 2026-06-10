import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Session snapshot autosave
extension AppDelegate {
    func startSessionAutosaveTimerIfNeeded() {
        guard sessionAutosaveTimer == nil else { return }
        let env = ProcessInfo.processInfo.environment
        guard !isRunningUnderXCTest(env) else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = SessionPersistencePolicy.autosaveInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self,
                  Self.shouldRunSessionAutosaveTick(isTerminatingApp: self.isTerminatingApp) else {
                return
            }
            self.runSessionAutosaveTick(source: "timer")
        }
        sessionAutosaveTimer = timer
        timer.resume()
    }

    func stopSessionAutosaveTimer() {
        sessionAutosaveTimer?.cancel()
        sessionAutosaveTimer = nil
        sessionAutosaveTickInFlight = false
        sessionAutosaveDeferredRetryPending = false
    }

    func installLifecycleSnapshotObserversIfNeeded() {
        guard !didInstallLifecycleSnapshotObservers else { return }
        didInstallLifecycleSnapshotObservers = true

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let powerOffObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTerminatingApp = true
                _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
                ClosedItemHistoryStore.shared.flushPendingSaves()
            }
        }
        lifecycleSnapshotObservers.append(powerOffObserver)

        let sessionResignObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isTerminatingApp {
                    _ = self.saveSessionSnapshotIncludingProcessDetectedIndexes(includeScrollback: true, removeWhenEmpty: false)
                    ClosedItemHistoryStore.shared.flushPendingSaves()
                } else {
                    self.saveSessionSnapshotAfterLoadingProcessDetectedIndexes(includeScrollback: false)
                }
            }
        }
        lifecycleSnapshotObservers.append(sessionResignObserver)

        let didWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartSocketListenerIfEnabled(source: "workspace.didWake")
            }
        }
        lifecycleSnapshotObservers.append(didWakeObserver)
    }

    func disableSuddenTerminationIfNeeded() {
        guard !didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.disableSuddenTermination()
        didDisableSuddenTermination = true
    }

    func enableSuddenTerminationIfNeeded() {
        guard didDisableSuddenTermination else { return }
        ProcessInfo.processInfo.enableSuddenTermination()
        didDisableSuddenTermination = false
    }

    private func sessionAutosaveFingerprint(
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex
    ) -> Int? {
        guard !includeScrollback else { return nil }

        var hasher = Hasher()
        let contexts = mainWindowContexts.values.sorted { lhs, rhs in
            lhs.windowId.uuidString < rhs.windowId.uuidString
        }
        hasher.combine(contexts.count)

        for context in contexts.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot) {
            hasher.combine(context.windowId)
            hasher.combine(
                context.tabManager.sessionAutosaveFingerprint(
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: surfaceResumeBindingIndex
                )
            )
            hasher.combine(context.sidebarState.isVisible)
            hasher.combine(
                Int(SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth)).rounded())
            )

            switch context.sidebarSelectionState.selection {
            case .tabs:
                hasher.combine(0)
            case .notifications:
                hasher.combine(1)
            }

            if let window = context.window ?? windowForMainWindowId(context.windowId) {
                Self.hashFrame(window.frame, into: &hasher)
            } else {
                hasher.combine(-1)
            }
        }

        return hasher.finalize()
    }

    @discardableResult
    func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false,
        restorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> Bool {
        if Self.shouldSkipSessionSaveDuringRestore(
            isApplyingSessionRestore: isApplyingSessionRestore,
            includeScrollback: includeScrollback
        ) {
#if DEBUG
            cmuxDebugLog("session.save.skipped reason=session_restore_in_progress includeScrollback=0")
#endif
            return false
        }
        let writeSynchronously = Self.shouldWriteSessionSnapshotSynchronously(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: includeScrollback
        )
        if writeSynchronously {
            TextBoxInputTextView.flushPendingSessionDraftAttachmentCopies()
        }
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "session.saveSnapshot",
                startedAt: timingStart,
                extra: "includeScrollback=\(includeScrollback ? 1 : 0) removeWhenEmpty=\(removeWhenEmpty ? 1 : 0) sync=\(writeSynchronously ? 1 : 0)"
            )
        }
#endif

        guard let snapshot = buildSessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        ) else {
            persistSessionSnapshot(
                nil,
                removeWhenEmpty: removeWhenEmpty,
                persistedGeometryData: nil,
                synchronously: writeSynchronously
            )
            return false
        }

        let persistedGeometryData = snapshot.windows.first.flatMap { primaryWindow in
            Self.encodedPersistedWindowGeometryData(
                frame: primaryWindow.frame,
                display: primaryWindow.display
            )
        }

#if DEBUG
        debugLogSessionSaveSnapshot(snapshot, includeScrollback: includeScrollback)
#endif
        persistSessionSnapshot(
            snapshot,
            removeWhenEmpty: false,
            persistedGeometryData: persistedGeometryData,
            synchronously: writeSynchronously
        )
        return true
    }

#if DEBUG
    func debugBenchmarkSessionSnapshot(
        includeScrollback: Bool,
        persist: Bool
    ) -> [String: Any] {
        SessionSnapshotDebugBenchmark.run(
            includeScrollback: includeScrollback,
            persist: persist,
            buildSnapshot: { [self] includeScrollback in
                buildSessionSnapshot(includeScrollback: includeScrollback)
            },
            persistedGeometryData: { snapshot in
                snapshot?.windows.first.flatMap { primaryWindow in
                    Self.encodedPersistedWindowGeometryData(
                        frame: primaryWindow.frame,
                        display: primaryWindow.display
                    )
                }
            },
            persistSnapshot: { [self] snapshot, persistedGeometryData in
                persistSessionSnapshot(
                    snapshot,
                    removeWhenEmpty: false,
                    persistedGeometryData: persistedGeometryData,
                    synchronously: true
                )
            }
        )
    }

    func debugBuildSessionSnapshotForTesting(
        includeScrollback: Bool,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> AppSessionSnapshot? {
        buildSessionSnapshot(
            includeScrollback: includeScrollback,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )
    }

    func debugSeedSessionSnapshotScrollback(charactersPerTerminal: Int) -> [String: Any] {
        let workspaces = sortedMainWindowContextsForSessionSnapshot().flatMap { context in
            context.tabManager.tabs.filter { !$0.isRemoteWorkspace }
        }
        return SessionSnapshotDebugBenchmark.seedScrollback(
            workspaces: workspaces,
            charactersPerTerminal: charactersPerTerminal
        )
    }
#endif

    nonisolated static func shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSaveSessionSnapshotAfterMainWindowRegistration(
        isTerminatingApp: Bool,
        didApplyStartupSessionRestore: Bool,
        isApplyingSessionRestore: Bool
    ) -> Bool {
        !isTerminatingApp && !didApplyStartupSessionRestore && !isApplyingSessionRestore
    }

    nonisolated static func shouldSkipSessionSaveDuringRestore(
        isApplyingSessionRestore: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isApplyingSessionRestore && !includeScrollback
    }

    nonisolated static func shouldRunSessionAutosaveTick(isTerminatingApp: Bool) -> Bool {
        !isTerminatingApp
    }

    nonisolated static func shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp _: Bool) -> Bool {
        // App switching must stay cheap. The autosave timer, window/session lifecycle,
        // power-off, update relaunch, and termination paths still persist session state.
        false
    }

    private func remainingSessionAutosaveTypingQuietPeriod(
        nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> TimeInterval? {
        guard lastTypingActivityAt > 0 else { return nil }
        let elapsed = nowUptime - lastTypingActivityAt
        guard elapsed < Self.sessionAutosaveTypingQuietPeriod else { return nil }
        return Self.sessionAutosaveTypingQuietPeriod - elapsed
    }

    private func scheduleDeferredSessionAutosaveRetry(after delay: TimeInterval) {
        guard delay.isFinite, delay > 0 else { return }
        guard !sessionAutosaveDeferredRetryPending else { return }
        sessionAutosaveDeferredRetryPending = true
        sessionPersistenceQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionAutosaveDeferredRetryPending = false
                self.runSessionAutosaveTick(source: "typingQuietRetry")
            }
        }
    }

    func runSessionAutosaveTick(source: String) {
        guard Self.shouldRunSessionAutosaveTick(isTerminatingApp: isTerminatingApp) else { return }
        guard !sessionAutosaveTickInFlight else { return }
        if let remainingQuietPeriod = remainingSessionAutosaveTypingQuietPeriod() {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=typing_recent includeScrollback=0 source=\(source) " +
                "retryMs=\(Int((remainingQuietPeriod * 1000).rounded()))"
            )
#endif
            scheduleDeferredSessionAutosaveRetry(after: remainingQuietPeriod)
            return
        }

        sessionAutosaveTickInFlight = true
        let generation = nextProcessDetectedSessionSaveGeneration()
        Task { @MainActor in await self.finishSessionAutosaveTick(source: source, generation: generation) }
    }

    private func finishSessionAutosaveTick(source: String, generation: UInt64) async {
#if DEBUG
        let timingStart = CmuxTypingTiming.start()
        let phaseStart = ProcessInfo.processInfo.systemUptime
        var fingerprintMs: Double = 0
        var saveMs: Double = 0
        defer {
            sessionAutosaveTickInFlight = false
            let totalMs = (ProcessInfo.processInfo.systemUptime - phaseStart) * 1000.0
            CmuxTypingTiming.logBreakdown(
                path: "session.autosaveTick.phase",
                totalMs: totalMs,
                thresholdMs: 2.0,
                parts: [
                    ("fingerprintMs", fingerprintMs),
                    ("saveMs", saveMs),
                ],
                extra: "source=\(source)"
            )
            CmuxTypingTiming.logDuration(
                path: "session.autosaveTick",
                startedAt: timingStart,
                extra: "source=\(source)"
            )
        }
#else
        defer { sessionAutosaveTickInFlight = false }
#endif

        let now = Date()
#if DEBUG
        let fingerprintStart = ProcessInfo.processInfo.systemUptime
#endif
        let resumeIndexes = await ProcessDetectedResumeIndexes.load()
        guard !isTerminatingApp,
              isCurrentProcessDetectedSessionSaveGeneration(generation) else {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=stale_process_detected_scan includeScrollback=0 source=\(source)"
            )
#endif
            return
        }
        let autosaveFingerprint = sessionAutosaveFingerprint(
            includeScrollback: false,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        fingerprintMs = (ProcessInfo.processInfo.systemUptime - fingerprintStart) * 1000.0
#endif
        if Self.shouldSkipSessionAutosaveForUnchangedFingerprint(
            isTerminatingApp: isTerminatingApp,
            includeScrollback: false,
            previousFingerprint: lastSessionAutosaveFingerprint,
            currentFingerprint: autosaveFingerprint,
            lastPersistedAt: lastSessionAutosavePersistedAt,
            now: now
        ) {
#if DEBUG
            cmuxDebugLog(
                "session.save.skipped reason=unchanged_autosave_fingerprint includeScrollback=0 source=\(source)"
            )
#endif
            return
        }

#if DEBUG
        let saveStart = ProcessInfo.processInfo.systemUptime
#endif
        _ = saveSessionSnapshot(
            includeScrollback: false,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
#if DEBUG
        saveMs = (ProcessInfo.processInfo.systemUptime - saveStart) * 1000.0
#endif
        updateSessionAutosaveSaveState(
            includeScrollback: false,
            persistedAt: now,
            fingerprint: autosaveFingerprint
        )
    }

    @discardableResult
    func saveSessionSnapshotIncludingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false
    ) -> Bool {
        let resumeIndexes = ProcessDetectedResumeIndexes.loadSynchronously()
        return saveSessionSnapshot(
            includeScrollback: includeScrollback,
            removeWhenEmpty: removeWhenEmpty,
            restorableAgentIndex: resumeIndexes.restorableAgentIndex,
            surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
        )
    }

    func saveSessionSnapshotAfterLoadingProcessDetectedIndexes(
        includeScrollback: Bool,
        removeWhenEmpty: Bool = false
    ) {
        let generation = nextProcessDetectedSessionSaveGeneration()
        Task { @MainActor [weak self] in
            let resumeIndexes = await ProcessDetectedResumeIndexes.load()
            guard let self,
                  !self.isTerminatingApp,
                  self.isCurrentProcessDetectedSessionSaveGeneration(generation) else { return }
            _ = self.saveSessionSnapshot(
                includeScrollback: includeScrollback,
                removeWhenEmpty: removeWhenEmpty,
                restorableAgentIndex: resumeIndexes.restorableAgentIndex,
                surfaceResumeBindingIndex: resumeIndexes.surfaceResumeBindingIndex
            )
        }
    }

    @discardableResult
    private func nextProcessDetectedSessionSaveGeneration() -> UInt64 {
        processDetectedSessionSaveGeneration &+= 1
        return processDetectedSessionSaveGeneration
    }

    private func isCurrentProcessDetectedSessionSaveGeneration(_ generation: UInt64) -> Bool {
        generation == processDetectedSessionSaveGeneration
    }

    func recordTypingActivity() {
        lastTypingActivityAt = ProcessInfo.processInfo.systemUptime
    }

    nonisolated static func shouldWriteSessionSnapshotSynchronously(
        isTerminatingApp: Bool,
        includeScrollback: Bool
    ) -> Bool {
        isTerminatingApp && includeScrollback
    }

    nonisolated static func shouldSkipSessionAutosaveForUnchangedFingerprint(
        isTerminatingApp: Bool,
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date,
        maximumAutosaveSkippableInterval: TimeInterval = 60
    ) -> Bool {
        guard !isTerminatingApp,
              !includeScrollback,
              let previousFingerprint,
              let currentFingerprint,
              previousFingerprint == currentFingerprint else {
            return false
        }

        return now.timeIntervalSince(lastPersistedAt) < maximumAutosaveSkippableInterval
    }

    private func updateSessionAutosaveSaveState(
        includeScrollback: Bool,
        persistedAt: Date,
        fingerprint: Int?
    ) {
        guard !isTerminatingApp, !includeScrollback else { return }
        lastSessionAutosaveFingerprint = fingerprint
        lastSessionAutosavePersistedAt = persistedAt
    }

    private nonisolated static func hashFrame(_ frame: NSRect, into hasher: inout Hasher) {
        let standardized = frame.standardized
        let quantized = [
            standardized.origin.x,
            standardized.origin.y,
            standardized.size.width,
            standardized.size.height,
        ].map { Int(($0 * 2).rounded()) }
        quantized.forEach { hasher.combine($0) }
    }

    private func persistSessionSnapshot(
        _ snapshot: AppSessionSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    ) {
        guard snapshot != nil || removeWhenEmpty || persistedGeometryData != nil else { return }

        let writeBlock = {
            Self.removeLegacyPersistedWindowGeometry()
            if let persistedGeometryData {
                UserDefaults.standard.set(
                    persistedGeometryData,
                    forKey: Self.persistedWindowGeometryDefaultsKey
                )
            }
            if let snapshot {
                _ = SessionPersistenceStore.save(snapshot)
            } else if removeWhenEmpty {
                SessionPersistenceStore.removeSnapshot()
            }
        }

        if synchronously {
            writeBlock()
        } else {
            sessionPersistenceQueue.async(execute: writeBlock)
        }
    }

    func sortedMainWindowContextsForSessionSnapshot() -> [MainWindowContext] {
        mainWindowContexts.values.sorted { lhs, rhs in
            let lhsWindow = lhs.window ?? windowForMainWindowId(lhs.windowId)
            let rhsWindow = rhs.window ?? windowForMainWindowId(rhs.windowId)
            let lhsIsKey = lhsWindow?.isKeyWindow ?? false
            let rhsIsKey = rhsWindow?.isKeyWindow ?? false
            if lhsIsKey != rhsIsKey {
                return lhsIsKey && !rhsIsKey
            }
            return lhs.windowId.uuidString < rhs.windowId.uuidString
        }
    }

    func buildSessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex suppliedRestorableAgentIndex: RestorableAgentSessionIndex? = nil,
        surfaceResumeBindingIndex suppliedSurfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> AppSessionSnapshot? {
        let contexts = sortedMainWindowContextsForSessionSnapshot()

        guard !contexts.isEmpty else { return nil }
        let restorableAgentIndex = suppliedRestorableAgentIndex ?? RestorableAgentSessionIndex.load()

        let windows: [SessionWindowSnapshot] = contexts
            .prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
            .map { context in
                sessionWindowSnapshot(
                    for: context,
                    includeScrollback: includeScrollback,
                    restorableAgentIndex: restorableAgentIndex,
                    surfaceResumeBindingIndex: suppliedSurfaceResumeBindingIndex
                )
            }

        guard !windows.isEmpty else { return nil }
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: windows
        )
    }

    func sessionWindowSnapshot(
        for context: MainWindowContext,
        includeScrollback: Bool,
        restorableAgentIndex: RestorableAgentSessionIndex,
        surfaceResumeBindingIndex: SurfaceResumeBindingIndex? = nil
    ) -> SessionWindowSnapshot {
        let tabManagerSnapshot = context.tabManager.sessionSnapshot(
            includeScrollback: includeScrollback,
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: surfaceResumeBindingIndex
        )

        let window = context.window ?? windowForMainWindowId(context.windowId)
        return SessionWindowSnapshot(
            windowId: context.windowId,
            frame: window.map { SessionRectSnapshot($0.frame) },
            display: displaySnapshot(for: window),
            tabManager: tabManagerSnapshot,
            sidebar: SessionSidebarSnapshot(
                isVisible: context.sidebarState.isVisible,
                selection: SessionSidebarSelection(selection: context.sidebarSelectionState.selection),
                width: SessionPersistencePolicy.sanitizedSidebarWidth(Double(context.sidebarState.persistedWidth))
            )
        )
    }

#if DEBUG
    private func debugLogSessionSaveSnapshot(
        _ snapshot: AppSessionSnapshot,
        includeScrollback: Bool
    ) {
        cmuxDebugLog(
            "session.save includeScrollback=\(includeScrollback ? 1 : 0) " +
                "windows=\(snapshot.windows.count)"
        )
        for (index, windowSnapshot) in snapshot.windows.enumerated() {
            let workspaceCount = windowSnapshot.tabManager.workspaces.count
            let selectedWorkspace = windowSnapshot.tabManager.selectedWorkspaceIndex.map(String.init) ?? "nil"
            cmuxDebugLog(
                "session.save.window idx=\(index) " +
                    "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))} " +
                    "workspaces=\(workspaceCount) selected=\(selectedWorkspace)"
            )
        }
    }

    func debugSessionRectDescription(_ rect: SessionRectSnapshot?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(rect.x)) y=\(debugSessionNumber(rect.y)) " +
            "w=\(debugSessionNumber(rect.width)) h=\(debugSessionNumber(rect.height))"
    }

    func debugNSRectDescription(_ rect: NSRect?) -> String {
        guard let rect else { return "nil" }
        return "x=\(debugSessionNumber(Double(rect.origin.x))) " +
            "y=\(debugSessionNumber(Double(rect.origin.y))) " +
            "w=\(debugSessionNumber(Double(rect.size.width))) " +
            "h=\(debugSessionNumber(Double(rect.size.height)))"
    }

    func debugSessionDisplayDescription(_ display: SessionDisplaySnapshot?) -> String {
        guard let display else { return "nil" }
        let displayIdText = display.displayID.map(String.init) ?? "nil"
        return "id=\(displayIdText) " +
            "frame={\(debugSessionRectDescription(display.frame))} " +
            "visible={\(debugSessionRectDescription(display.visibleFrame))}"
    }

    private func debugSessionNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
#endif

}
