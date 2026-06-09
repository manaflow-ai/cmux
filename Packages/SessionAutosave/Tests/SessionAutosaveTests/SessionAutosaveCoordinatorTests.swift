import SessionAutosave
import XCTest

final class SessionAutosaveCoordinatorTests: XCTestCase {
    @MainActor
    func testSerializesTicksAndIgnoresStaleFinish() throws {
        let coordinator = SessionAutosaveCoordinator<Int>()
        var startedCount = 0
        var firstRunToken: SessionAutosaveCoordinator<Int>.RunToken?

        XCTAssertTrue(
            coordinator.beginTick { runToken in
                startedCount += 1
                firstRunToken = runToken
                return Task {}
            }
        )
        XCTAssertFalse(
            coordinator.beginTick { _ in
                startedCount += 1
                return Task {}
            }
        )

        coordinator.finishTick(runToken: SessionAutosaveCoordinator<Int>.RunToken())
        XCTAssertFalse(
            coordinator.beginTick { _ in
                startedCount += 1
                return Task {}
            }
        )

        coordinator.finishTick(runToken: try XCTUnwrap(firstRunToken))
        XCTAssertTrue(
            coordinator.beginTick { _ in
                startedCount += 1
                return Task {}
            }
        )
        coordinator.cancelInFlightTick()

        XCTAssertEqual(startedCount, 2)
    }

    @MainActor
    func testTracksTypingQuietPeriod() throws {
        let coordinator = SessionAutosaveCoordinator<Int>()

        XCTAssertNil(coordinator.remainingTypingQuietPeriod(quietPeriod: 0.65, nowUptime: 100))
        coordinator.recordTypingActivity(nowUptime: 100)

        XCTAssertEqual(
            try XCTUnwrap(coordinator.remainingTypingQuietPeriod(quietPeriod: 0.65, nowUptime: 100.25)),
            0.40,
            accuracy: 0.001
        )
        XCTAssertNil(coordinator.remainingTypingQuietPeriod(quietPeriod: 0.65, nowUptime: 101))
    }

    @MainActor
    func testTracksPersistedFingerprint() {
        let coordinator = SessionAutosaveCoordinator<Int>()
        let now = Date()

        XCTAssertFalse(
            coordinator.shouldSkipSaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                currentFingerprint: 42,
                now: now,
                maximumAutosaveSkippableInterval: 60
            )
        )

        coordinator.recordSuccessfulSave(
            isTerminatingApp: false,
            includeScrollback: false,
            persistedAt: now,
            fingerprint: 42
        )

        XCTAssertTrue(
            coordinator.shouldSkipSaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                currentFingerprint: 42,
                now: now.addingTimeInterval(10),
                maximumAutosaveSkippableInterval: 60
            )
        )
        XCTAssertFalse(
            coordinator.shouldSkipSaveForUnchangedFingerprint(
                isTerminatingApp: false,
                includeScrollback: false,
                currentFingerprint: 43,
                now: now.addingTimeInterval(10),
                maximumAutosaveSkippableInterval: 60
            )
        )
    }

    @MainActor
    func testUsesExplicitCachedThenFallbackSnapshots() {
        let coordinator = SessionAutosaveCoordinator<Int>()
        var fallbackCount = 0

        XCTAssertEqual(
            coordinator.snapshotForCheapSave(explicitSnapshot: nil) {
                fallbackCount += 1
                return 1
            },
            1
        )
        XCTAssertEqual(
            coordinator.snapshotForCheapSave(explicitSnapshot: nil) {
                fallbackCount += 1
                return 2
            },
            1
        )
        XCTAssertEqual(
            coordinator.snapshotForCheapSave(explicitSnapshot: 3) {
                fallbackCount += 1
                return 4
            },
            3
        )
        XCTAssertEqual(fallbackCount, 1)
    }
}
