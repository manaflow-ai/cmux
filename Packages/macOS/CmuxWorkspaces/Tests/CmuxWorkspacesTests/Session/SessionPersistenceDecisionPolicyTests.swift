import CoreGraphics
import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("SessionPersistenceDecisionPolicy")
struct SessionPersistenceDecisionPolicyTests {
    private let policy = SessionPersistenceDecisionPolicy()

    @Test("persists on window unregister unless terminating")
    func persistsOnWindowUnregister() {
        #expect(policy.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: false))
        #expect(!policy.shouldPersistSnapshotOnWindowUnregister(isTerminatingApp: true))
    }

    @Test("saves after main-window registration only outside terminate/restore")
    func savesAfterMainWindowRegistration() {
        #expect(
            policy.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: false
            )
        )
        #expect(
            !policy.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: true,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: false
            )
        )
        #expect(
            !policy.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: true,
                isApplyingSessionRestore: false
            )
        )
        #expect(
            !policy.shouldSaveSessionSnapshotAfterMainWindowRegistration(
                isTerminatingApp: false,
                didApplyStartupSessionRestore: false,
                isApplyingSessionRestore: true
            )
        )
    }

    @Test("skips non-scrollback save while a restore applies")
    func skipsSaveDuringRestore() {
        #expect(
            policy.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: true,
                includeScrollback: false
            )
        )
        #expect(
            !policy.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: true,
                includeScrollback: true
            )
        )
        #expect(
            !policy.shouldSkipSessionSaveDuringRestore(
                isApplyingSessionRestore: false,
                includeScrollback: false
            )
        )
    }

    @Test("runs autosave tick unless terminating")
    func runsAutosaveTick() {
        #expect(policy.shouldRunSessionAutosaveTick(isTerminatingApp: false))
        #expect(!policy.shouldRunSessionAutosaveTick(isTerminatingApp: true))
    }

    @Test("never saves on application resign")
    func neverSavesOnResign() {
        #expect(!policy.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: false))
        #expect(!policy.shouldSaveSessionSnapshotOnApplicationResign(isTerminatingApp: true))
    }

    @Test("saves on restore completion unless a manual reopen")
    func savesOnRestoreCompletion() {
        #expect(policy.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: false))
        #expect(!policy.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: true))
    }

    @Test("writes synchronously only on terminating scrollback save")
    func writesSynchronously() {
        #expect(
            policy.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: true
            )
        )
        #expect(
            !policy.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: true,
                includeScrollback: false
            )
        )
        #expect(
            !policy.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: true
            )
        )
        #expect(
            !policy.shouldWriteSessionSnapshotSynchronously(
                isTerminatingApp: false,
                includeScrollback: false
            )
        )
    }

    @Test("skips unchanged autosave fingerprint within the staleness window")
    func skipsUnchangedFingerprintWithinWindow() {
        let now = Date()
        #expect(
            policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-5),
                now: now
            )
        )
    }

    @Test("does not skip unchanged autosave fingerprint after the staleness window")
    func doesNotSkipUnchangedFingerprintAfterWindow() {
        let now = Date()
        #expect(
            !policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-120),
                now: now
            )
        )
    }

    @Test("never skips terminating, scrollback, missing, or differing fingerprints")
    func neverSkipsGuardedCases() {
        let now = Date()
        #expect(
            !policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: true,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        #expect(
            !policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: true,
                previousFingerprint: 1234,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        #expect(
            !policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: nil,
                currentFingerprint: 1234,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
        #expect(
            !policy.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1234,
                currentFingerprint: 5678,
                lastPersistedAt: now.addingTimeInterval(-1),
                now: now
            )
        )
    }

    @Test("custom skippable interval shifts the staleness boundary")
    func customSkippableInterval() {
        let now = Date()
        let shortWindow = SessionPersistenceDecisionPolicy(maximumAutosaveSkippableInterval: 10)
        #expect(
            !shortWindow.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1,
                currentFingerprint: 1,
                lastPersistedAt: now.addingTimeInterval(-30),
                now: now
            )
        )
        #expect(
            shortWindow.shouldSkipSessionAutosaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                previousFingerprint: 1,
                currentFingerprint: 1,
                lastPersistedAt: now.addingTimeInterval(-3),
                now: now
            )
        )
    }

    @Test("hashFrame quantizes to half points and is jitter-stable")
    func hashFrameQuantizes() {
        func digest(_ rect: CGRect) -> Int {
            var hasher = Hasher()
            policy.hashFrame(rect, into: &hasher)
            return hasher.finalize()
        }
        // Sub-quarter-point jitter rounds to the same half-point quantum.
        #expect(
            digest(CGRect(x: 100.0, y: 200.0, width: 800.0, height: 600.0))
                == digest(CGRect(x: 100.2, y: 200.2, width: 800.2, height: 600.2))
        )
        // A half-point shift crosses a quantum boundary.
        #expect(
            digest(CGRect(x: 100.0, y: 200.0, width: 800.0, height: 600.0))
                != digest(CGRect(x: 100.5, y: 200.0, width: 800.0, height: 600.0))
        )
    }
}
