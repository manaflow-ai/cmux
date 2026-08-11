import AppKit
import Dispatch
import Foundation
import GhosttyKit
import os
import Testing
import CmuxTerminalCore
@testable import CmuxTerminal

@MainActor
@Suite struct TerminalSurfaceRestoreSpawnSchedulerTests {
    @Test func restoredSurfaceSpawnsDrainOnePerDelay() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<3).map { _ in UUID() }
        var spawned: [UUID] = []

        for id in ids {
            scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
                spawned.append(id)
            }
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        delayer.releaseNextDelay()
        await delayer.waitForDelayCount(2)
        #expect(spawned == [ids[0], ids[1]])

        delayer.releaseNextDelay()
        await waitForSpawnCount(3, spawned: { spawned.count })
        #expect(spawned == ids)
    }

    @Test func twelveRestoredSurfaceBurstDrainsOneNativeSpawnPerCadence() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<12).map { _ in UUID() }
        var spawned: [UUID] = []

        for id in ids {
            scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
                spawned.append(id)
            }
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        for expectedSpawnCount in 2...ids.count {
            delayer.releaseNextDelay()
            await waitForSpawnCount(expectedSpawnCount, spawned: { spawned.count })
            #expect(spawned == Array(ids.prefix(expectedSpawnCount)))
        }

        #expect(spawned == ids)
    }

    @Test func duplicateReadinessCallbacksForOneSurfaceCoalesce() async {
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero)
        let id = UUID()
        var spawned: [String] = []

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
            spawned.append("first")
        }
        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: id) {
            spawned.append("duplicate")
        }

        await waitForSpawnCount(1, spawned: { spawned.count })
        #expect(spawned == ["first"])
    }

    @Test func laterReadinessDuringCooldownStillWaitsForDelay() async {
        let delayer = ManualRestoreSpawnDelayer()
        let scheduler = TerminalSurfaceRestoreSpawnScheduler(
            interSpawnDelay: .milliseconds(125),
            delayer: delayer
        )
        let ids = (0..<2).map { _ in UUID() }
        var spawned: [UUID] = []

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: ids[0]) {
            spawned.append(ids[0])
        }

        await delayer.waitForDelayCount(1)
        #expect(spawned == [ids[0]])

        scheduler.scheduleRestoredSurfaceSpawn(surfaceId: ids[1]) {
            spawned.append(ids[1])
        }

        #expect(spawned == [ids[0]])

        delayer.releaseNextDelay()
        await waitForSpawnCount(2, spawned: { spawned.count })
        #expect(spawned == ids)
    }

    @Test func restorePacedTerminalSurfaceQueuesNativeCreationBeforeGhosttyWork() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(scheduler: scheduler, nativeView: nativeView, paneHost: paneHost)
        surface.agentCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func restorePacedTerminalSurfaceWaitsForAgentShimsBeforeEnteringSpawnQueue() async throws {
        _ = try #require(Bundle.main.resourceURL)
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let shimInstaller = ManualAgentCommandShimInstaller()
        let runtimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: {
                await shimInstaller.install(wrapperDirectoryURL: $0, surfaceId: $1, temporaryDirectory: $2)
            },
            isExecutableFile: { _ in false }
        )
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeFilesystem: runtimeFilesystem
        )
        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-shim-gate")
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.createSurface(for: nativeView)
        await shimInstaller.waitForInstallStart()

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)

        await shimInstaller.complete()
        await waitForSpawnCount(1, spawned: { scheduler.scheduledSurfaceIds.count })

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
    }

    @Test func scheduledRestoreCreationCanRequeueWhenTheViewIsNotReady() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        scheduler.runScheduledOperation()
        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds == [surface.id, surface.id])
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func immediateTerminalSurfaceBypassesRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            runtimeSpawnPolicy: .immediate,
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func runtimeCreationRetriesAfterTeardownAdmissionRecovers() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 4
        )
        let retainedSurfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer { for retainedSurface in retainedSurfaces { retainedSurface.deallocate() } }
        let runtimeReservations = try (0..<retainedSurfaces.count).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let freeStarted = AsyncStream<Void>.makeStream()
        let releaseFrees = DispatchSemaphore(value: 0)
        defer {
            releaseFrees.signal()
            releaseFrees.signal()
            freeStarted.continuation.finish()
        }

        let tickets = try retainedSurfaces.enumerated().map { index, retainedSurface in
            let ticket = coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.creationRetry.\(index)",
                surface: retainedSurface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: runtimeReservations[index],
                freeSurface: { _ in
                    freeStarted.continuation.yield()
                    releaseFrees.wait()
                }
            )
            return try #require(ticket)
        }
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()
        _ = await freeStartedIterator.next()

        let degradationDeadline = ContinuousClock.now + .seconds(1)
        while await !coordinator.debugCloseTeardownDegraded,
              ContinuousClock.now < degradationDeadline {
            await Task.yield()
        }
        #expect(await coordinator.debugCloseTeardownDegraded)

        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let surface = makeSurface(
            runtimeSpawnPolicy: .immediate,
            scheduler: RecordingRestoreSpawnScheduler(),
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeTeardown: coordinator
        )
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)

        releaseFrees.signal()
        let retryDeadline = ContinuousClock.now + .seconds(1)
        while surface.debugRuntimeSurfaceCreateAttemptCountForTesting() < 2,
              ContinuousClock.now < retryDeadline {
            await Task.yield()
        }

        #expect(
            surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 2,
            "surface creation was not retried after native ownership admission recovered"
        )
        releaseFrees.signal()
        for ticket in tickets {
            #expect(await ticket.wait(timeout: .seconds(1)))
        }
    }

    @Test func restoredCreationReentersPacingAfterAdmissionRecovers() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 4
        )
        let retainedSurfaces = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        defer {
            for retainedSurface in retainedSurfaces {
                retainedSurface.deallocate()
            }
        }
        let runtimeReservations = try (0..<retainedSurfaces.count).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let freeStarted = AsyncStream<Void>.makeStream()
        let releaseFrees = DispatchSemaphore(value: 0)
        defer {
            releaseFrees.signal()
            releaseFrees.signal()
            freeStarted.continuation.finish()
        }

        let tickets = try retainedSurfaces.enumerated().map {
            index,
            retainedSurface in
            let ticket = coordinator.enqueueRuntimeTeardown(
                id: UUID(),
                workspaceId: UUID(),
                reason: "test.pacedCreationRetry.\(index)",
                surface: retainedSurface,
                callbackContext: nil,
                manualIOContext: nil,
                byteTeeLease: nil,
                runtimeOwnershipReservation: runtimeReservations[index],
                freeSurface: { _ in
                    freeStarted.continuation.yield()
                    releaseFrees.wait()
                }
            )
            return try #require(ticket)
        }
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = await freeStartedIterator.next()
        _ = await freeStartedIterator.next()

        let degradationDeadline = ContinuousClock.now + .seconds(1)
        while await !coordinator.debugCloseTeardownDegraded,
              ContinuousClock.now < degradationDeadline {
            await Task.yield()
        }
        #expect(await coordinator.debugCloseTeardownDegraded)

        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            runtimeTeardown: coordinator
        )
        surface.scheduleHeadlessRuntimeStartIfNeeded(
            reason: "test-admission-recovery-pacing"
        )
        defer { surface.closeHeadlessStartupWindowIfNeeded() }
        surface.attachedView = nativeView
        surface.claudeCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        scheduler.runScheduledOperation()
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)

        releaseFrees.signal()
        let recoveryDeadline = ContinuousClock.now + .seconds(1)
        while scheduler.scheduledSurfaceIds.count < 2,
              surface.debugRuntimeSurfaceCreateAttemptCountForTesting() < 2,
              ContinuousClock.now < recoveryDeadline {
            await Task.yield()
        }

        #expect(scheduler.scheduledSurfaceIds == [surface.id, surface.id])
        #expect(
            surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1,
            "admission recovery bypassed restored-surface spawn pacing"
        )
        releaseFrees.signal()
        for ticket in tickets {
            #expect(await ticket.wait(timeout: .seconds(1)))
        }
    }

    @Test func overflowedCreationRetriesInAdmissionOrder() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(coordinator)
        defer { releaseRuntimeOwnershipSaturation(saturation, from: coordinator) }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixtures = (0..<2).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }

        for (index, fixture) in fixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
            try #require(
                fixture.surface.runtimeSurfaceAdmissionDeferredCreationSource
                    == .scheduledRestore
            )
        }

        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(4)

        #expect(
            scheduler.scheduledSurfaceIds == [
                fixtures[0].surface.id,
                fixtures[1].surface.id,
                fixtures[0].surface.id,
                fixtures[1].surface.id,
            ]
        )
        #expect(
            registry.allSurfacesCallCount == 0,
            "overflow recovery must not scan the full surface registry"
        )
    }

    @Test func overflowRecoveryWaitsForEveryOlderPrimaryRequest() async throws {
        let ownerCount = 4
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: ownerCount
        )
        let owners = try (0..<ownerCount).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        defer {
            for owner in owners {
                coordinator.cancelRuntimeSurfaceOwnership(owner)
            }
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixtures = (0...ownerCount).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }

        for (index, fixture) in fixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
            try #require(
                fixture.surface.runtimeSurfaceAdmissionDeferredCreationSource
                    == .scheduledRestore
            )
        }

        for owner in owners {
            coordinator.cancelRuntimeSurfaceOwnership(owner)
        }
        await scheduler.waitForScheduledCount(fixtures.count * 2)

        #expect(
            Array(scheduler.scheduledSurfaceIds.suffix(fixtures.count))
                == fixtures.map { $0.surface.id }
        )
    }

    @Test func overflowRecoveryContinuesInFixedMainActorBatches() async throws {
        let batchCount = 32
        let overflowCount = batchCount + 1
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: overflowCount
        )
        let saturation = try saturateRuntimeOwnershipRecovery(
            coordinator,
            count: overflowCount
        )
        defer {
            releaseRuntimeOwnershipSaturation(saturation, from: coordinator)
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixtures = (0..<overflowCount).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }

        for (index, fixture) in fixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
            try #require(
                fixture.surface.runtimeSurfaceAdmissionDeferredCreationSource
                    == .scheduledRestore
            )
        }

        for owner in saturation.owners {
            coordinator.cancelRuntimeSurfaceOwnership(owner)
        }
        await scheduler.waitForScheduledCount(overflowCount + batchCount)

        #expect(scheduler.scheduledSurfaceIds.count == overflowCount + batchCount)
        await scheduler.waitForScheduledCount(overflowCount * 2)
        #expect(
            Array(scheduler.scheduledSurfaceIds.suffix(overflowCount))
                == fixtures.map { $0.surface.id }
        )
        #expect(registry.allSurfacesCallCount == 0)
    }

    @Test func overflowCancellationChurnEmptiesIndexAndLinkedOrder() {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let fixture = makeSurfaceFixture(
            registry: FakeSurfaceRegistry(),
            scheduler: RecordingRestoreSpawnScheduler(),
            runtimeTeardown: coordinator
        )
        var previousSequence: UInt64 = 0

        for _ in 0..<(32 * 2 + 1) {
            let surfaceID = UUID()
            let registration = coordinator
                .registerRuntimeSurfaceOwnershipRecoveryOverflow(
                    surfaceID: surfaceID,
                    surface: fixture.surface
                )
            let expectedSequence = previousSequence + 1
            #expect(registration == .registered(sequence: expectedSequence))
            previousSequence = registration.sequence ?? previousSequence
            coordinator.cancelRuntimeSurfaceOwnershipRecoveryOverflow(
                surfaceID: surfaceID
            )
        }

        let emptySnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(emptySnapshot.entryCount == 0)
        #expect(emptySnapshot.linkedNodeCount == 0)
        #expect(emptySnapshot.headID == nil)
        #expect(emptySnapshot.tailID == nil)

        let repeatedID = UUID()
        let firstSequence = coordinator
            .registerRuntimeSurfaceOwnershipRecoveryOverflow(
                surfaceID: repeatedID,
                surface: fixture.surface
            )
        let updatedSequence = coordinator
            .registerRuntimeSurfaceOwnershipRecoveryOverflow(
                surfaceID: repeatedID,
                surface: fixture.surface
            )
        let updatedSnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        let firstSequenceValue = firstSequence.sequence
        #expect(firstSequenceValue != nil)
        #expect(
            firstSequence
                == .registered(sequence: firstSequenceValue ?? 0)
        )
        #expect(
            updatedSequence
                == .updated(sequence: firstSequenceValue ?? 0)
        )
        #expect(updatedSnapshot.entryCount == 1)
        #expect(updatedSnapshot.linkedNodeCount == 1)
        #expect(updatedSnapshot.headID == repeatedID)
        #expect(updatedSnapshot.tailID == repeatedID)

        coordinator.cancelRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: repeatedID
        )
        let replacementSequence = coordinator
            .registerRuntimeSurfaceOwnershipRecoveryOverflow(
                surfaceID: repeatedID,
                surface: fixture.surface
            )
        #expect(
            replacementSequence
                == .registered(sequence: (firstSequenceValue ?? 0) + 1)
        )
        coordinator.cancelRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: repeatedID
        )

        let finalSnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(finalSnapshot.entryCount == 0)
        #expect(finalSnapshot.linkedNodeCount == 0)
        #expect(finalSnapshot.headID == nil)
        #expect(finalSnapshot.tailID == nil)
    }

    @Test func overflowStoreIsBoundedAndSameIDUpdatesStayCapacityNeutral() {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let fixture = makeSurfaceFixture(
            registry: FakeSurfaceRegistry(),
            scheduler: RecordingRestoreSpawnScheduler(),
            runtimeTeardown: coordinator
        )
        let firstID = UUID()
        let secondID = UUID()

        let first = coordinator.registerRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: firstID,
            surface: fixture.surface
        )
        let second = coordinator.registerRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: secondID,
            surface: fixture.surface
        )
        let updated = coordinator.registerRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: secondID,
            surface: fixture.surface
        )
        let rejected = coordinator.registerRuntimeSurfaceOwnershipRecoveryOverflow(
            surfaceID: UUID(),
            surface: fixture.surface
        )

        #expect(first == .registered(sequence: 1))
        #expect(second == .registered(sequence: 2))
        #expect(updated == .updated(sequence: 2))
        #expect(rejected == .rejected)
        let snapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(snapshot.entryCount == 2)
        #expect(snapshot.linkedNodeCount == 2)
        #expect(snapshot.headID == firstID)
        #expect(snapshot.tailID == secondID)
    }

    @Test func fullOverflowStoreReportsFailureAndKeepsAdmittedFIFOService() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(
            coordinator,
            count: 2
        )
        defer {
            releaseRuntimeOwnershipSaturation(saturation, from: coordinator)
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixtures = (0..<3).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }

        for (index, fixture) in fixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
        }

        let expectedMessage = String(
            localized: "terminal.surface.runtimeCreation.capacityExceeded",
            defaultValue:
                "Unable to start this terminal because too many terminal sessions are still closing."
        )
        #expect(
            fixtures[2].surface
                .runtimeSurfaceAdmissionDeferredCreationSource == nil
        )
        #expect(
            fixtures[2].paneHost.runtimeSurfaceCreationFailureMessages
                == [expectedMessage]
        )
        let fullSnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(fullSnapshot.entryCount == 2)
        #expect(fullSnapshot.headID == fixtures[0].surface.id)
        #expect(fullSnapshot.tailID == fixtures[1].surface.id)

        coordinator.cancelRuntimeSurfaceOwnershipRecovery(
            saturation.recoveryIDs[0]
        )
        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(4)

        #expect(scheduler.scheduledSurfaceIds.last == fixtures[0].surface.id)
    }

    @Test func successfulRuntimeSurfaceCreationClearsCapacityFailure() {
        let fixture = makeSurfaceFixture(
            registry: FakeSurfaceRegistry(),
            scheduler: RecordingRestoreSpawnScheduler(),
            runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator()
        )
        TerminalSurface.runtimeSurfaceFreeOverrideForTesting = { _ in }
        defer {
            fixture.surface.releaseSurfaceForTesting()
            TerminalSurface.runtimeSurfaceFreeOverrideForTesting = nil
        }

        fixture.surface.failRuntimeSurfaceCreationForTeardownCapacity()
        #expect(
            fixture.paneHost.activeRuntimeSurfaceCreationFailureMessage != nil
        )

        fixture.surface.installRuntimeSurfaceForTesting(
            UnsafeMutableRawPointer(bitPattern: 0x7542)!
        )

        #expect(
            fixture.paneHost.activeRuntimeSurfaceCreationFailureMessage == nil
        )
    }

    @Test func stalledCloseWorkersFailDeferredCreationAndRecoverSafely() async throws {
        let clock = ManualTerminalSurfaceRuntimeTeardownClock()
        let stalledSlots = AsyncStream<Int>.makeStream()
        let finishFreeStarted = DispatchSemaphore(value: 0)
        let releaseFinishFree = DispatchSemaphore(value: 0)
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2,
            closeTeardownTimeout: .seconds(5),
            closeTeardownClock: clock,
            closeTeardownStalledObserver: { slot in
                stalledSlots.continuation.yield(slot)
            }
        )
        let pointers = (0..<2).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
        }
        let freeStarted = AsyncStream<Int>.makeStream()
        let releaseFrees = (0..<2).map { _ in DispatchSemaphore(value: 0) }
        let freedPointerBits = OSAllocatedUnfairLock(initialState: [UInt]())
        defer {
            for releaseFree in releaseFrees {
                releaseFree.signal()
            }
            for pointer in pointers {
                pointer.deallocate()
            }
            freeStarted.continuation.finish()
            stalledSlots.continuation.finish()
            releaseFinishFree.signal()
        }
        let reservations = try (0..<2).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let tickets = try pointers.enumerated().map { index, pointer in
            let byteTeeLease: (any TerminalByteTeeLease)? = index == 0
                ? FakeTerminalByteTeeLease {
                    finishFreeStarted.signal()
                    releaseFinishFree.wait()
                }
                : nil
            try #require(
                coordinator.enqueueRuntimeTeardown(
                    id: UUID(),
                    workspaceId: UUID(),
                    reason: "test.stalledClose.\(index)",
                    surface: pointer,
                    callbackContext: nil,
                    manualIOContext: nil,
                    byteTeeLease: byteTeeLease,
                    runtimeOwnershipReservation: reservations[index],
                    freeSurface: { pointer in
                        freeStarted.continuation.yield(index)
                        releaseFrees[index].wait()
                        freedPointerBits.withLock {
                            $0.append(UInt(bitPattern: pointer))
                        }
                    }
                )
            )
        }
        var freeStartedIterator = freeStarted.stream.makeAsyncIterator()
        _ = try #require(await freeStartedIterator.next())
        _ = try #require(await freeStartedIterator.next())
        var registrationIterator = clock.registrations.makeAsyncIterator()
        let firstWatchdog = try #require(await registrationIterator.next())
        let secondWatchdog = try #require(await registrationIterator.next())

        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let deferredFixtures = (0..<3).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }
        for (index, fixture) in deferredFixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
        }

        var stalledSlotIterator = stalledSlots.stream.makeAsyncIterator()
        clock.fire(firstWatchdog)
        _ = try #require(await stalledSlotIterator.next())
        #expect(
            deferredFixtures.allSatisfy {
                $0.paneHost.runtimeSurfaceCreationFailureMessages.isEmpty
            }
        )

        var failureIterators = deferredFixtures.map {
            $0.paneHost.runtimeSurfaceCreationFailures.makeAsyncIterator()
        }
        clock.fire(secondWatchdog)
        _ = try #require(await stalledSlotIterator.next())
        let expectedMessage = String(
            localized: "terminal.surface.runtimeCreation.capacityExceeded",
            defaultValue:
                "Unable to start this terminal because too many terminal sessions are still closing."
        )
        for index in failureIterators.indices {
            #expect(
                try #require(await failureIterators[index].next())
                    == expectedMessage
            )
            #expect(
                deferredFixtures[index].surface
                    .runtimeSurfaceAdmissionDeferredCreationSource != nil
            )
        }
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .entryCount == 1
        )

        let rejectedAfterStall = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        var postStallFailureIterator = rejectedAfterStall.paneHost
            .runtimeSurfaceCreationFailures.makeAsyncIterator()
        rejectedAfterStall.surface.createSurface(
            for: rejectedAfterStall.nativeView
        )
        scheduler.runScheduledOperation(at: deferredFixtures.count)
        #expect(
            try #require(await postStallFailureIterator.next())
                == expectedMessage
        )
        #expect(
            rejectedAfterStall.surface
                .runtimeSurfaceAdmissionDeferredCreationSource != nil
        )
        let firstDeferredAttemptCount = deferredFixtures[0].surface
            .debugRuntimeSurfaceCreateAttemptCountForTesting()

        let stalledStateAfterFree = Task.detached {
            finishFreeStarted.wait()
            let stalled = coordinator.debugCloseTeardownAllStalled
            releaseFinishFree.signal()
            return stalled
        }
        releaseFrees[0].signal()
        let remainedAllStalled = await stalledStateAfterFree.value
        #expect(
            !remainedAllStalled,
            "returned close worker retained the all-stalled admission failure"
        )
        #expect(await tickets[0].wait(timeout: nil))
        await waitForMainActorQueueBarrier()
        #expect(
            deferredFixtures[0].surface
                .debugRuntimeSurfaceCreateAttemptCountForTesting()
                == firstDeferredAttemptCount + 1
        )
        #expect(
            deferredFixtures[0].surface
                .runtimeSurfaceAdmissionDeferredCreationSource == nil
        )
        #expect(
            freedPointerBits.withLock { $0 }
                == [UInt(bitPattern: pointers[0])]
        )
        let recoveredReservation = try #require(
            coordinator.reserveRuntimeSurfaceOwnership()
        )
        coordinator.cancelRuntimeSurfaceOwnership(recoveredReservation)
        #expect(!coordinator.debugCloseTeardownAllStalled)

        releaseFrees[1].signal()
        #expect(await tickets[1].wait(timeout: nil))
        #expect(
            Set(freedPointerBits.withLock { $0 })
                == Set(pointers.map { UInt(bitPattern: $0) })
        )
        #expect(coordinator.debugRuntimeSurfaceOwnerCount == 0)
    }

    @Test func completedFailureBatchRescansOverflowAndIgnoresStaleFailure() async throws {
        let capacity = 34
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: capacity
        )
        let owners = try (0..<capacity).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        defer {
            for owner in owners {
                coordinator.cancelRuntimeSurfaceOwnership(owner)
            }
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixtures = (0..<capacity).map { _ in
            makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
        }
        for (index, fixture) in fixtures.enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
        }

        let failures = coordinator.runtimeOwnershipAdmission
            .failRecoveriesForAllStalledCloseTeardowns()
        #expect(failures.count == capacity)
        coordinator.runtimeOwnershipAdmission.clearAllStalledCloseTeardowns()

        let overflow = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        overflow.surface.createSurface(for: overflow.nativeView)
        scheduler.runScheduledOperation(at: capacity)
        await waitForMainActorQueueBarrier()
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .headID == overflow.surface.id
        )

        for failure in failures.prefix(32) {
            failure()
        }
        coordinator.cancelRuntimeSurfaceOwnership(owners[0])
        let target = try #require(fixtures.last)
        let targetAttemptCount = target.surface
            .debugRuntimeSurfaceCreateAttemptCountForTesting()
        target.surface.createSurface(
            for: target.nativeView,
            source: .inputDemand
        )
        #expect(
            target.surface.debugRuntimeSurfaceCreateAttemptCountForTesting()
                == targetAttemptCount + 1
        )

        coordinator.runtimeOwnershipAdmission
            .completeStalledCloseRecoveryFailures(
                Array(failures.prefix(32))
            )
        await waitForMainActorQueueBarrier()
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .headID == nil
        )

        for failure in failures.suffix(from: 32) {
            failure()
        }
        coordinator.runtimeOwnershipAdmission
            .completeStalledCloseRecoveryFailures(
                Array(failures.suffix(from: 32))
            )
        #expect(target.paneHost.runtimeSurfaceCreationFailureMessages.isEmpty)
        overflow.surface.beginPortalCloseLifecycle(
            reason: "test.completedFailureBatch"
        )
    }

    @Test func lifecycleCancellationSynchronouslyRemovesOverflowEntries() throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(
            coordinator,
            count: 2
        )
        defer {
            releaseRuntimeOwnershipSaturation(saturation, from: coordinator)
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()

        let closing = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        closing.surface.createSurface(for: closing.nativeView)
        scheduler.runScheduledOperation(at: 0)
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .entryCount == 1
        )
        closing.surface.beginPortalCloseLifecycle(reason: "test.overflowClose")
        assertOverflowStorageIsEmpty(coordinator)

        let hibernating = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        hibernating.surface.createSurface(for: hibernating.nativeView)
        scheduler.runScheduledOperation(at: 1)
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .entryCount == 1
        )
        #expect(
            hibernating.surface.suspendRuntimeSurfaceForAgentHibernation(
                reason: "test.overflowHibernate"
            )
        )
        assertOverflowStorageIsEmpty(coordinator)

        let deinitView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        var deinitializing: TerminalSurface? = makeSurface(
            scheduler: scheduler,
            nativeView: deinitView,
            paneHost: FakeTerminalSurfacePaneHost(surfaceView: deinitView),
            registry: registry,
            runtimeTeardown: coordinator
        )
        deinitializing?.agentCommandShimInstallCompleted = true
        deinitializing?.createSurface(for: deinitView)
        scheduler.runScheduledOperation(at: 2)
        #expect(
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
                .entryCount == 1
        )
        weak var weakDeinitializing = deinitializing
        deinitializing = nil
        #expect(weakDeinitializing == nil)
        assertOverflowStorageIsEmpty(coordinator)
    }

    @Test func overflowCancelAfterCapacitySignalLeavesOnlyLiveFIFOHead() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(
            coordinator,
            count: 2
        )
        defer {
            releaseRuntimeOwnershipSaturation(saturation, from: coordinator)
        }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let cancelled = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        let sentinel = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )

        for (index, fixture) in [cancelled, sentinel].enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
        }
        let queuedSnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(queuedSnapshot.entryCount == 2)
        #expect(queuedSnapshot.linkedNodeCount == 2)
        #expect(queuedSnapshot.headID == cancelled.surface.id)
        #expect(queuedSnapshot.tailID == sentinel.surface.id)

        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        cancelled.surface.beginPortalCloseLifecycle(
            reason: "test.cancelAfterCapacitySignal"
        )
        let cancelledSnapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(cancelledSnapshot.entryCount == 1)
        #expect(cancelledSnapshot.linkedNodeCount == 1)
        #expect(cancelledSnapshot.headID == sentinel.surface.id)
        #expect(cancelledSnapshot.tailID == sentinel.surface.id)

        await scheduler.waitForScheduledCount(3)
        #expect(
            scheduler.scheduledSurfaceIds == [
                cancelled.surface.id,
                sentinel.surface.id,
                sentinel.surface.id,
            ]
        )
        assertOverflowStorageIsEmpty(coordinator)
    }

    @Test func overflowStoreSurvivesImmediateRecoveryCapacityRelease() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(coordinator)
        defer { releaseRuntimeOwnershipSaturation(saturation, from: coordinator) }
        let scheduler = RecordingRestoreSpawnScheduler()
        let fixture = makeSurfaceFixture(
            registry: FakeSurfaceRegistry(),
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )

        fixture.surface.createSurface(for: fixture.nativeView)
        scheduler.runScheduledOperation()
        try #require(
            fixture.surface.runtimeSurfaceAdmissionDeferredCreationSource
                == .scheduledRestore
        )

        coordinator.cancelRuntimeSurfaceOwnershipRecovery(
            saturation.recoveryIDs[0]
        )
        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(2)

        #expect(
            scheduler.scheduledSurfaceIds == [
                fixture.surface.id,
                fixture.surface.id,
            ]
        )
    }

    @Test func repeatedOverflowForOneSurfaceCoalescesAndPromotesSource() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(coordinator)
        defer { releaseRuntimeOwnershipSaturation(saturation, from: coordinator) }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let repeated = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        let sentinel = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )

        repeated.surface.createSurface(for: repeated.nativeView)
        scheduler.runScheduledOperation(at: 0)
        repeated.surface.createSurface(
            for: repeated.nativeView,
            source: .inputDemand
        )
        try #require(
            repeated.surface.runtimeSurfaceAdmissionDeferredCreationSource
                == .inputDemand
        )
        sentinel.surface.createSurface(for: sentinel.nativeView)
        scheduler.runScheduledOperation(at: 1)
        try #require(
            sentinel.surface.runtimeSurfaceAdmissionDeferredCreationSource
                == .scheduledRestore
        )

        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(3)

        #expect(
            repeated.surface.debugRuntimeSurfaceCreateAttemptCountForTesting()
                == 3
        )
        #expect(
            scheduler.scheduledSurfaceIds == [
                repeated.surface.id,
                sentinel.surface.id,
                sentinel.surface.id,
            ]
        )
    }

    @Test func deinitializedOverflowSurfaceIsNotRetried() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(coordinator)
        defer { releaseRuntimeOwnershipSaturation(saturation, from: coordinator) }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        var deadFixture: (
            surface: TerminalSurface?,
            nativeView: FakeTerminalSurfaceNativeView
        ) = {
            let fixture = makeSurfaceFixture(
                registry: registry,
                scheduler: scheduler,
                runtimeTeardown: coordinator
            )
            return (Optional(fixture.surface), fixture.nativeView)
        }()
        let deadSurfaceID = try #require(deadFixture.surface?.id)
        weak var weakDeadSurface = deadFixture.surface

        deadFixture.surface?.createSurface(for: deadFixture.nativeView)
        scheduler.runScheduledOperation(at: 0)
        try #require(
            deadFixture.surface?.runtimeSurfaceAdmissionDeferredCreationSource
                == .scheduledRestore
        )
        deadFixture.surface = nil
        try #require(weakDeadSurface == nil)

        let sentinel = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        sentinel.surface.createSurface(for: sentinel.nativeView)
        scheduler.runScheduledOperation(at: 1)
        try #require(
            sentinel.surface.runtimeSurfaceAdmissionDeferredCreationSource
                == .scheduledRestore
        )

        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(3)

        #expect(
            scheduler.scheduledSurfaceIds.filter { $0 == deadSurfaceID }.count
                == 1
        )
        #expect(
            scheduler.scheduledSurfaceIds.last == sentinel.surface.id
        )
    }

    @Test func cancelledOverflowSurfaceIsRemovedBeforeCapacityReturns() async throws {
        let coordinator = TerminalSurfaceRuntimeTeardownCoordinator(
            maximumRuntimeSurfaceOwnerCount: 2
        )
        let saturation = try saturateRuntimeOwnershipRecovery(coordinator)
        defer { releaseRuntimeOwnershipSaturation(saturation, from: coordinator) }
        let registry = FakeSurfaceRegistry()
        let scheduler = RecordingRestoreSpawnScheduler()
        let cancelled = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )
        let sentinel = makeSurfaceFixture(
            registry: registry,
            scheduler: scheduler,
            runtimeTeardown: coordinator
        )

        for (index, fixture) in [cancelled, sentinel].enumerated() {
            fixture.surface.createSurface(for: fixture.nativeView)
            scheduler.runScheduledOperation(at: index)
            try #require(
                fixture.surface.runtimeSurfaceAdmissionDeferredCreationSource
                    == .scheduledRestore
            )
        }
        cancelled.surface.beginPortalCloseLifecycle(reason: "test.cancelOverflow")

        coordinator.cancelRuntimeSurfaceOwnership(saturation.owners[0])
        await scheduler.waitForScheduledCount(3)

        #expect(
            scheduler.scheduledSurfaceIds == [
                cancelled.surface.id,
                sentinel.surface.id,
                sentinel.surface.id,
            ]
        )
        #expect(registry.allSurfacesCallCount == 0)
    }

    @Test func configurationReloadDefersAndPromotesRuntimeCreation() {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost =
            FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let engine = FakeTerminalEngine()
        engine
            .shouldDeferRuntimeSurfaceCreationForConfigurationReload =
            true
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            engine: engine
        )
        surface.agentCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        surface.createSurface(
            for: nativeView,
            source: .inputDemand
        )

        #expect(
            engine.deferredRuntimeSurfaceCreationActions.count == 1
        )
        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(
            surface
                .debugRuntimeSurfaceCreateAttemptCountForTesting()
                == 0
        )

        engine
            .shouldDeferRuntimeSurfaceCreationForConfigurationReload =
            false
        engine.runNextDeferredRuntimeSurfaceCreation()

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(
            surface
                .debugRuntimeSurfaceCreateAttemptCountForTesting()
                == 1
        )
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func inputDemandForRestorePacedTerminalBypassesPendingRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true

        surface.createSurface(for: nativeView)
        surface.createSurface(for: nativeView, source: .inputDemand)

        #expect(scheduler.scheduledSurfaceIds == [surface.id])
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func postShimScheduledRestoreDoesNotTailAppendReadyViewToRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-ready-slot")
        defer { surface.closeHeadlessStartupWindowIfNeeded() }
        surface.attachedView = nativeView
        surface.agentCommandShimInstallCompleted = true

        #expect(nativeView.window != nil)
        surface.resumeSurfaceCreationAfterAgentCommandShimsReady(
            view: nativeView,
            source: .scheduledRestore
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func postShimScheduledRestoreWithoutReadyViewDoesNotTailAppendToRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true

        surface.resumeSurfaceCreationAfterAgentCommandShimsReady(
            view: nativeView,
            source: .scheduledRestore
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 0)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func queuedSocketInputPromotesBackgroundStartToInputDemand() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.backgroundSurfaceStartQueued = true
        surface.backgroundSurfaceStartSource = .normal

        #expect(surface.sendText("echo queued\n"))

        #expect(surface.backgroundSurfaceStartQueued)
        #expect(surface.backgroundSurfaceStartSource == .inputDemand)
        #expect(scheduler.scheduledSurfaceIds.isEmpty)
    }

    @Test func inputDemandHeadlessStartDoesNotQueueRestoreSpawnThroughPaneHostAttach() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(
            surfaceView: nativeView,
            attachesThroughSurfaceModel: true
        )
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.scheduleHeadlessRuntimeStartIfNeeded(reason: "test-input-demand", source: .inputDemand)

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    @Test func inputDemandPromotesInFlightAgentShimCreationSource() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallTask = Task { nil }
        defer {
            surface.agentCommandShimInstallTask?.cancel()
            surface.agentCommandShimInstallTask = nil
            surface.agentCommandShimPendingCreationSource = nil
        }

        _ = surface.agentCommandShimStateForSurface(view: nativeView, source: .scheduledRestore)
        _ = surface.agentCommandShimStateForSurface(view: nativeView, source: .inputDemand)

        #expect(surface.agentCommandShimPendingCreationSource == .inputDemand)
    }

    @Test func inputDemandShimFallbackStartsHeadlessWithoutRestoreQueue() {
        let nativeView = FakeTerminalSurfaceNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let scheduler = RecordingRestoreSpawnScheduler()
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost
        )
        surface.agentCommandShimInstallCompleted = true
        defer { surface.closeHeadlessStartupWindowIfNeeded() }

        surface.resumeSurfaceCreationAfterAgentCommandShimsReady(
            view: nil,
            source: .inputDemand
        )

        #expect(scheduler.scheduledSurfaceIds.isEmpty)
        #expect(surface.debugRuntimeSurfaceCreateAttemptCountForTesting() == 1)
        #expect(surface.runtimeSurfacePointer == nil)
    }

    private func waitForSpawnCount(_ count: Int, spawned: () -> Int) async {
        for _ in 0..<100 {
            if spawned() >= count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(count) scheduled restored surface spawns")
    }

    private func makeSurface(
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .pacedSessionRestore,
        scheduler: RecordingRestoreSpawnScheduler,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost,
        registry: any TerminalSurfaceRegistering = FakeSurfaceRegistry(),
        engine: FakeTerminalEngine = FakeTerminalEngine(),
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator =
            TerminalSurfaceRuntimeTeardownCoordinator(),
        runtimeFilesystem: TerminalSurfaceRuntimeFilesystem = TerminalSurfaceRuntimeFilesystem(
            agentCommandShimTemporaryDirectory: URL(fileURLWithPath: "/tmp/cmux-terminal-tests", isDirectory: true),
            installAgentCommandShims: { _, _, _ in nil },
            isExecutableFile: { _ in false }
        )
    ) -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: engine,
                viewProvider: FakeTerminalSurfaceViewProvider(surfaceView: nativeView, paneHost: paneHost),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: runtimeTeardown,
                restoreSpawnScheduler: scheduler,
                runtimeFilesystem: runtimeFilesystem,
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "CMUX_TEST_SCROLLBACK_REPLAY"
            )
        )
    }

    private func makeSurfaceFixture(
        registry: any TerminalSurfaceRegistering,
        scheduler: RecordingRestoreSpawnScheduler,
        runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator
    ) -> (
        surface: TerminalSurface,
        nativeView: FakeTerminalSurfaceNativeView,
        paneHost: FakeTerminalSurfacePaneHost
    ) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView)
        let surface = makeSurface(
            scheduler: scheduler,
            nativeView: nativeView,
            paneHost: paneHost,
            registry: registry,
            runtimeTeardown: runtimeTeardown
        )
        surface.agentCommandShimInstallCompleted = true
        return (surface, nativeView, paneHost)
    }

    private func saturateRuntimeOwnershipRecovery(
        _ coordinator: TerminalSurfaceRuntimeTeardownCoordinator,
        count: Int = 2
    ) throws -> (
        owners: [TerminalSurfaceRuntimeOwnershipReservation],
        recoveryIDs: [UUID]
    ) {
        let owners = try (0..<count).map { _ in
            try #require(coordinator.reserveRuntimeSurfaceOwnership())
        }
        let recoveryIDs = (0..<count).map { _ in UUID() }
        for recoveryID in recoveryIDs {
            #expect(
                coordinator.reserveRuntimeSurfaceOwnership(
                    recoveryID: recoveryID,
                    onRecovery: { reservation in
                        coordinator.cancelRuntimeSurfaceOwnership(reservation)
                    }
                ) == .deferred
            )
        }
        return (owners, recoveryIDs)
    }

    private func releaseRuntimeOwnershipSaturation(
        _ saturation: (
            owners: [TerminalSurfaceRuntimeOwnershipReservation],
            recoveryIDs: [UUID]
        ),
        from coordinator: TerminalSurfaceRuntimeTeardownCoordinator
    ) {
        for recoveryID in saturation.recoveryIDs {
            coordinator.cancelRuntimeSurfaceOwnershipRecovery(recoveryID)
        }
        for owner in saturation.owners {
            coordinator.cancelRuntimeSurfaceOwnership(owner)
        }
    }

    private func assertOverflowStorageIsEmpty(
        _ coordinator: TerminalSurfaceRuntimeTeardownCoordinator
    ) {
        let snapshot =
            coordinator.debugRuntimeSurfaceOwnershipRecoveryOverflowSnapshot
        #expect(snapshot.entryCount == 0)
        #expect(snapshot.linkedNodeCount == 0)
        #expect(snapshot.headID == nil)
        #expect(snapshot.tailID == nil)
    }

    private func waitForMainActorQueueBarrier() async {
        await Task.detached {
            await MainActor.run {}
        }.value
    }
}
