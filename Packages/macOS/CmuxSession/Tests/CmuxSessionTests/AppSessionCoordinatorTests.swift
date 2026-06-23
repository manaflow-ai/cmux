import Foundation
import Testing
@testable import CmuxSession
import CmuxWorkspaces

/// Minimal snapshot/geometry wire stand-ins conforming to the EXISTING
/// CmuxWorkspaces seams, proving the coordinator never names a concrete wire
/// type and works against any conformer.
private struct FakeSnapshot: SessionSnapshotRepresenting {
    var version: Int
    var hasWindows: Bool
}

private struct FakeResumeIndexes: AppSessionResumeIndexCarrying {}

@MainActor
private final class FakeHost: AppSessionHosting {
    typealias Snapshot = FakeSnapshot
    typealias GeometryPayload = FakeSnapshotGeometry

    struct FakeSnapshotGeometry: WindowGeometryPersisting {
        var version: Int
    }

    var isTerminatingApp = false
    var shouldAttemptRestore = true
    var startupSnapshot: FakeSnapshot?
    var reopenSnapshot: FakeSnapshot?

    var removeLegacyCalls = 0
    var syncBackupCalls = 0
    var loadStartupCalls = 0
    var saveCalls: [(includeScrollback: Bool, removeWhenEmpty: Bool, hasIndexes: Bool)] = []
    var applyStartupCalls = 0
    var applyFallbackCalls = 0
    var applyManualCalls = 0
    var skipSaveDuringRestore = false
    var skipUnchangedFingerprint = false
    var saveOnRestoreCompletion = true
    var fingerprintValue: Int? = 7

    func shouldAttemptStartupRestore() -> Bool { shouldAttemptRestore }
    func removeLegacyWindowGeometry() { removeLegacyCalls += 1 }
    func syncManualRestoreSnapshotCache() { syncBackupCalls += 1 }
    func loadStartupSnapshot() -> FakeSnapshot? { loadStartupCalls += 1; return startupSnapshot }

    func buildSessionSnapshot(
        includeScrollback: Bool,
        restorableAgentIndex: AppSessionResumeIndexes?
    ) -> FakeSnapshot? { startupSnapshot }

    func encodedPrimaryWindowGeometryData(for snapshot: FakeSnapshot) -> Data? { nil }

    func persist(
        snapshot: FakeSnapshot?,
        removeWhenEmpty: Bool,
        persistedGeometryData: Data?,
        synchronously: Bool
    ) {}

    func shouldWriteSessionSnapshotSynchronously(includeScrollback: Bool) -> Bool { includeScrollback }
    func shouldSkipSessionSaveDuringRestore(includeScrollback: Bool) -> Bool { skipSaveDuringRestore }
    func shouldSkipSessionAutosaveForUnchangedFingerprint(
        includeScrollback: Bool,
        previousFingerprint: Int?,
        currentFingerprint: Int?,
        lastPersistedAt: Date,
        now: Date
    ) -> Bool { skipUnchangedFingerprint }
    func shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: Bool) -> Bool { saveOnRestoreCompletion }

    func sessionAutosaveFingerprint(
        includeScrollback: Bool,
        restorableAgentIndex: AppSessionResumeIndexes
    ) -> Int? { fingerprintValue }

    @discardableResult
    func saveSessionSnapshot(
        includeScrollback: Bool,
        removeWhenEmpty: Bool,
        restorableAgentIndex: AppSessionResumeIndexes?
    ) -> Bool {
        saveCalls.append((includeScrollback, removeWhenEmpty, restorableAgentIndex != nil))
        return startupSnapshot != nil
    }

    func loadProcessDetectedResumeIndexes() async -> AppSessionResumeIndexes {
        AppSessionResumeIndexes(payload: FakeResumeIndexes())
    }
    func loadProcessDetectedResumeIndexesSynchronously() -> AppSessionResumeIndexes {
        AppSessionResumeIndexes(payload: FakeResumeIndexes())
    }

    func applyStartupRestore(snapshot: FakeSnapshot) -> Bool { applyStartupCalls += 1; return true }
    func applyStartupRestoreFallbackGeometry() { applyFallbackCalls += 1 }
    func applyManualRestore(snapshot: FakeSnapshot, shouldActivate: Bool) -> Bool {
        applyManualCalls += 1
        return true
    }
    func loadReopenSessionSnapshot() -> FakeSnapshot? { reopenSnapshot }
}

@MainActor
@Suite struct AppSessionCoordinatorTests {
    private func makeCoordinator(_ host: FakeHost) -> AppSessionCoordinator<FakeHost> {
        let coordinator = AppSessionCoordinator<FakeHost>()
        coordinator.attach(host: host)
        return coordinator
    }

    @Test func prepareIsIdempotentAndLoadsSnapshotWhenAllowed() {
        let host = FakeHost()
        host.startupSnapshot = FakeSnapshot(version: 1, hasWindows: true)
        let coordinator = makeCoordinator(host)

        coordinator.prepareStartupSnapshotIfNeeded()
        coordinator.prepareStartupSnapshotIfNeeded()

        #expect(host.removeLegacyCalls == 1)
        #expect(host.syncBackupCalls == 1)
        #expect(host.loadStartupCalls == 1)
        #expect(coordinator.startupSessionSnapshot?.hasWindows == true)
    }

    @Test func prepareSkipsLoadWhenRestoreDisallowed() {
        let host = FakeHost()
        host.shouldAttemptRestore = false
        let coordinator = makeCoordinator(host)

        coordinator.prepareStartupSnapshotIfNeeded()

        #expect(host.loadStartupCalls == 0)
        #expect(coordinator.startupSessionSnapshot == nil)
    }

    @Test func startupRestoreAppliesSnapshotOnceThenLatches() {
        let host = FakeHost()
        host.startupSnapshot = FakeSnapshot(version: 1, hasWindows: true)
        let coordinator = makeCoordinator(host)
        coordinator.prepareStartupSnapshotIfNeeded()

        #expect(coordinator.attemptStartupRestoreIfNeeded() == true)
        #expect(host.applyStartupCalls == 1)
        #expect(coordinator.isApplyingSessionRestore == true)

        // Latched: a second attempt is a no-op.
        #expect(coordinator.attemptStartupRestoreIfNeeded() == false)
        #expect(host.applyStartupCalls == 1)
    }

    @Test func startupRestoreUsesFallbackWhenNoSnapshot() {
        let host = FakeHost()
        let coordinator = makeCoordinator(host)
        coordinator.prepareStartupSnapshotIfNeeded()

        #expect(coordinator.attemptStartupRestoreIfNeeded() == false)
        #expect(host.applyFallbackCalls == 1)
        #expect(host.applyStartupCalls == 0)
    }

    @Test func completeRestoreClearsStateAndSavesWhenPolicyAllows() {
        let host = FakeHost()
        host.startupSnapshot = FakeSnapshot(version: 1, hasWindows: true)
        let coordinator = makeCoordinator(host)
        coordinator.prepareStartupSnapshotIfNeeded()
        _ = coordinator.attemptStartupRestoreIfNeeded()

        coordinator.completeRestore(isManualReopen: false)

        #expect(coordinator.isApplyingSessionRestore == false)
        #expect(coordinator.startupSessionSnapshot == nil)
        #expect(host.saveCalls.count == 1)
    }

    @Test func saveSkippedDuringRestore() {
        let host = FakeHost()
        host.skipSaveDuringRestore = true
        let coordinator = makeCoordinator(host)

        #expect(coordinator.saveSessionSnapshot(includeScrollback: false) == false)
        #expect(host.saveCalls.isEmpty)
    }

    @Test func autosaveSkipsOnUnchangedFingerprint() async {
        let host = FakeHost()
        host.skipUnchangedFingerprint = true
        let coordinator = makeCoordinator(host)

        await coordinator.performScheduledAutosave(source: "test")

        #expect(host.saveCalls.isEmpty)
    }

    @Test func autosaveWritesWhenFingerprintChanged() async {
        let host = FakeHost()
        host.startupSnapshot = FakeSnapshot(version: 1, hasWindows: true)
        host.skipUnchangedFingerprint = false
        let coordinator = makeCoordinator(host)

        await coordinator.performScheduledAutosave(source: "test")

        #expect(host.saveCalls.count == 1)
        #expect(host.saveCalls.first?.includeScrollback == false)
        #expect(host.saveCalls.first?.hasIndexes == true)
    }

    @Test func reopenPreviousSessionRestoresBackup() {
        let host = FakeHost()
        host.reopenSnapshot = FakeSnapshot(version: 1, hasWindows: true)
        let coordinator = makeCoordinator(host)

        #expect(coordinator.reopenPreviousSession(shouldActivate: false) == true)
        #expect(host.applyManualCalls == 1)
        #expect(coordinator.didAttemptStartupSessionRestore == true)
    }
}
