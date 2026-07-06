import CoreGraphics
import Foundation
import Testing

@testable import CmuxWorkspaces

@Suite("SessionSnapshotBuilder")
struct SessionSnapshotBuilderTests {
    private let builder = SessionSnapshotBuilder()

    // MARK: - assembleWindows

    @Test("keeps every window when none drop and the cap is not reached")
    func keepsEveryWindow() {
        let inputs = (0..<3).map { index in
            SessionSnapshotWindowInput(snapshot: index, dropsWhenEmptyDedicatedRemoteWindow: false)
        }
        let windows = builder.assembleWindows(from: inputs, maxWindows: 12)
        #expect(windows == [0, 1, 2])
    }

    @Test("drops windows flagged as empty dedicated remote, preserving order")
    func dropsEmptyDedicatedRemoteWindows() {
        let inputs = [
            SessionSnapshotWindowInput(snapshot: "a", dropsWhenEmptyDedicatedRemoteWindow: false),
            SessionSnapshotWindowInput(snapshot: "b", dropsWhenEmptyDedicatedRemoteWindow: true),
            SessionSnapshotWindowInput(snapshot: "c", dropsWhenEmptyDedicatedRemoteWindow: false),
        ]
        let windows = builder.assembleWindows(from: inputs, maxWindows: 12)
        #expect(windows == ["a", "c"])
    }

    @Test("caps the surviving window count at maxWindows, applied AFTER the drop")
    func capsAfterDrop() {
        // First input drops; without applying the cap after the drop, the legacy
        // prefix on the post-compactMap sequence would still yield maxWindows
        // survivors. Verify the cap counts survivors, not raw inputs.
        var inputs = [SessionSnapshotWindowInput(snapshot: -1, dropsWhenEmptyDedicatedRemoteWindow: true)]
        inputs += (0..<5).map {
            SessionSnapshotWindowInput(snapshot: $0, dropsWhenEmptyDedicatedRemoteWindow: false)
        }
        let windows = builder.assembleWindows(from: inputs, maxWindows: 3)
        #expect(windows == [0, 1, 2])
    }

    @Test("does not build per-window snapshots beyond the cap (lazy input is consumed lazily)")
    func consumesInputLazily() {
        var builtIndexes: [Int] = []
        let lazyInputs = (0..<20).lazy.map { index -> SessionSnapshotWindowInput<Int> in
            builtIndexes.append(index)
            return SessionSnapshotWindowInput(snapshot: index, dropsWhenEmptyDedicatedRemoteWindow: false)
        }
        let windows = builder.assembleWindows(from: lazyInputs, maxWindows: 4)
        #expect(windows == [0, 1, 2, 3])
        // Only the windows up to the cap are materialized, matching the legacy
        // `contexts.lazy.compactMap { ... }.prefix(maxWindows)`.
        #expect(builtIndexes == [0, 1, 2, 3])
    }

    @Test("returns an empty list for empty input")
    func emptyInput() {
        let inputs: [SessionSnapshotWindowInput<Int>] = []
        #expect(builder.assembleWindows(from: inputs, maxWindows: 12).isEmpty)
    }

    @Test("snapshot result reports crash diagnostic removal while dropping removed windows")
    func snapshotResultReportsCrashDiagnosticRemoval() {
        let inputs = [
            SessionSnapshotWindowInput(snapshot: "project", dropsWhenEmptyDedicatedRemoteWindow: false),
            SessionSnapshotWindowInput(
                snapshot: "crash",
                dropsWhenEmptyDedicatedRemoteWindow: false,
                dropsWhenCrashDiagnosticWindowRemoved: true,
                removedCrashDiagnosticState: true
            ),
            SessionSnapshotWindowInput(snapshot: "after", dropsWhenEmptyDedicatedRemoteWindow: false),
        ]

        let result = builder.assembleWindowSnapshotResult(from: inputs, maxWindows: 12)

        #expect(result.windows == ["project", "after"])
        #expect(result.removedCrashDiagnosticState)
    }

    // MARK: - fingerprint

    private func input(
        windowId: UUID,
        tabManagerFingerprint: Int,
        sidebarIsVisible: Bool = true,
        quantizedSidebarWidth: Int = 216,
        sidebarSelectionTag: Int = 0,
        frame: CGRect? = nil
    ) -> SessionSnapshotFingerprintWindowInput {
        SessionSnapshotFingerprintWindowInput(
            windowId: windowId,
            tabManagerFingerprint: tabManagerFingerprint,
            sidebarIsVisible: sidebarIsVisible,
            quantizedSidebarWidth: quantizedSidebarWidth,
            sidebarSelectionTag: sidebarSelectionTag,
            foldFrame: { hasher in
                if let frame {
                    SessionPersistenceDecisionPolicy().hashFrame(frame, into: &hasher)
                } else {
                    hasher.combine(-1)
                }
            }
        )
    }

    /// Re-derives the legacy fold by hand so the service result is pinned to the
    /// exact `sessionAutosaveFingerprint` ordering (full window count, then
    /// per-window windowId / tabManagerFP / sidebarIsVisible / quantizedWidth /
    /// selection / frame over the already-capped inputs).
    private func legacyFingerprint(
        cappedInputs: [SessionSnapshotFingerprintWindowInput],
        windowCount: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(windowCount)
        for input in cappedInputs {
            hasher.combine(input.windowId)
            hasher.combine(input.tabManagerFingerprint)
            hasher.combine(input.sidebarIsVisible)
            hasher.combine(input.quantizedSidebarWidth)
            hasher.combine(input.sidebarSelectionTag)
            input.foldFrame(&hasher)
        }
        return hasher.finalize()
    }

    @Test("fingerprint matches the legacy hand-derived fold")
    func fingerprintMatchesLegacyFold() {
        let inputs = [
            input(windowId: UUID(), tabManagerFingerprint: 11, frame: CGRect(x: 1, y: 2, width: 300, height: 400)),
            input(windowId: UUID(), tabManagerFingerprint: 22, sidebarIsVisible: false, sidebarSelectionTag: 1),
            input(windowId: UUID(), tabManagerFingerprint: 33),
        ]
        #expect(
            builder.fingerprint(cappedInputs: inputs, windowCount: inputs.count)
                == legacyFingerprint(cappedInputs: inputs, windowCount: inputs.count)
        )
    }

    @Test("fingerprint combines the FULL window count, independent of the capped fold")
    func fingerprintFullCount() {
        // The host caps the inputs and passes the full count separately, so two
        // calls with the SAME capped inputs but a DIFFERENT full window count must
        // produce different fingerprints (the legacy `hasher.combine(contexts.count)`).
        let capped = (0..<12).map { input(windowId: UUID(), tabManagerFingerprint: $0) }
        let twelveWindows = builder.fingerprint(cappedInputs: capped, windowCount: 12)
        let twentyWindows = builder.fingerprint(cappedInputs: capped, windowCount: 20)
        #expect(twelveWindows != twentyWindows)
    }

    @Test("a different tab-manager fingerprint changes the result")
    func tabManagerFingerprintParticipates() {
        let id = UUID()
        let a = [input(windowId: id, tabManagerFingerprint: 1)]
        let b = [input(windowId: id, tabManagerFingerprint: 2)]
        #expect(
            builder.fingerprint(cappedInputs: a, windowCount: 1)
                != builder.fingerprint(cappedInputs: b, windowCount: 1)
        )
    }

    @Test("the missing-frame branch folds -1, distinct from a real frame")
    func missingFrameBranch() {
        let id = UUID()
        let withFrame = [input(windowId: id, tabManagerFingerprint: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let withoutFrame = [input(windowId: id, tabManagerFingerprint: 1, frame: nil)]
        #expect(
            builder.fingerprint(cappedInputs: withFrame, windowCount: 1)
                != builder.fingerprint(cappedInputs: withoutFrame, windowCount: 1)
        )
    }
}
