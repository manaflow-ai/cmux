import CmuxFoundation
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator location route lifecycle")
struct SimulatorControlServiceLocationLifecycleTests {
    @Test("Same-device location mutations remain serialized")
    func sameDeviceMutationsAreSerialized() async throws {
        let commands = BlockingLocationCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: SimulatorLocationOwnershipScope()
        )
        let deviceID = UUID().uuidString
        let first = Task {
            try await service.setLocation(
                deviceID: deviceID,
                coordinate: SimulatorLocationCoordinate(latitude: 1, longitude: 2)
            )
        }
        await commands.waitForInvocationCount(1)
        let second = Task { try await service.clearLocation(deviceID: deviceID) }

        for _ in 0..<100 { await Task.yield() }
        #expect(await commands.arguments().count == 1)

        await commands.releaseFirstCommand()
        try await first.value
        try await second.value

        #expect(await commands.arguments() == [
            ["simctl", "location", deviceID, "set", "1.0,2.0"],
            ["simctl", "location", deviceID, "clear"],
        ])
    }

    @Test("Durable recovery preserves the legacy cross-process ownership namespace")
    func durableRecoveryPreservesLegacyOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-scope-compatibility-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let ownershipDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        let recoveryDirectory = root.appendingPathComponent("durable", isDirectory: true)
        let deviceID = UUID().uuidString
        let legacyScope = SimulatorLocationOwnershipScope(directory: ownershipDirectory)
        let legacyToken = try await legacyScope.registry.claim(deviceIdentifier: deviceID)
        let durableScope = SimulatorLocationOwnershipScope(
            ownershipDirectory: ownershipDirectory,
            recoveryDirectory: recoveryDirectory
        )

        #expect(
            await durableScope.registry.publishedToken(deviceIdentifier: deviceID)
                == legacyToken
        )
    }

    @Test("A non-loop route completes, replays, and restores its first waypoint")
    func completionReplayAndRestore() async throws {
        let commands = LocationLifecycleCommandRunner()
        let sleeper = LocationLifecycleSleepGate()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(),
            routeSleep: { duration in try await sleeper.sleep(for: duration) }
        )
        let route = Self.route()

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)
        await sleeper.waitForStartCount(1)
        #expect(await service.activeLocationRoutes["DEVICE"] != nil)

        await sleeper.advance()
        await eventually {
            let activeRoute = await service.activeLocationRoutes["DEVICE"]
            let lifecycleTask = await service.locationLifecycleTasks["DEVICE"]
            let token = await service.locationRouteTokens["DEVICE"]
            return activeRoute == nil && lifecycleTask == nil && token != nil
        }
        #expect(await service.locationRouteInitialCoordinates["DEVICE"] == route.waypoints[0])

        try await service.startLocationRoute(deviceID: "DEVICE", route: route)
        await sleeper.waitForStartCount(2)
        #expect(await service.activeLocationRoutes["DEVICE"] != nil)

        try await service.stopLocationRoute(deviceID: "DEVICE")
        await sleeper.waitForCancellationCount(1)

        let arguments = await commands.arguments()
        #expect(arguments.filter { $0.prefix(4) == ["simctl", "location", "DEVICE", "start"] }.count == 2)
        #expect(arguments.suffix(2) == [
            ["simctl", "location", "DEVICE", "clear"],
            ["simctl", "location", "DEVICE", "set", "37.7,-122.4"],
        ])
        #expect(await service.activeLocationRoutes["DEVICE"] == nil)
        #expect(await service.locationRouteInitialCoordinates["DEVICE"] == nil)
    }

    @Test("A replacement service restores a route from its persisted rollback journal")
    func replacementServiceRestoresPersistedRoute() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-route-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let route = Self.route()
        let firstService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )
        try await firstService.startLocationRoute(deviceID: deviceID, route: route)

        let replacementCommands = LocationLifecycleCommandRunner()
        let replacementService = SimulatorControlService(
            commands: replacementCommands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )
        try await replacementService.stopLocationRoute(deviceID: deviceID)

        #expect(await replacementCommands.arguments() == [
            ["simctl", "location", deviceID, "clear"],
            ["simctl", "location", deviceID, "set", "37.7,-122.4"],
        ])
    }

    @Test("Recovery restores ownership when a replacement dies before journaling")
    func recoveryReconcilesUnjournaledOwnershipClaim() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-owner-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerCommands = LocationLifecycleCommandRunner()
        let ownerScope = SimulatorLocationOwnershipScope(directory: directory)
        let ownerService = SimulatorControlService(
            commands: ownerCommands,
            locationOwnershipScope: ownerScope
        )
        try await ownerService.startLocationRoute(deviceID: deviceID, route: Self.route())

        let failedReplacementScope = SimulatorLocationOwnershipScope(directory: directory)
        _ = try await failedReplacementScope.registry.claim(deviceIdentifier: deviceID)
        let recoveryService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )

        #expect(await recoveryService.recoverOrphanedLocationRoutes())
        try await ownerService.stopLocationRoute(deviceID: deviceID)

        #expect(await ownerCommands.arguments().suffix(2) == [
            ["simctl", "location", deviceID, "clear"],
            ["simctl", "location", deviceID, "set", "37.7,-122.4"],
        ])
    }

    @Test("Recovery discards a pending route before ownership publication")
    func recoveryDiscardsUnpublishedPendingRoute() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-unpublished-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerScope = SimulatorLocationOwnershipScope(directory: directory)
        let ownerService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: ownerScope
        )
        try await ownerService.startLocationRoute(deviceID: deviceID, route: Self.route())
        let committedRecord = try #require(
            try ownerScope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        let committedSnapshot = try #require(committedRecord.committed)
        let pendingToken = UUID()
        let deadOwner = SimulatorProcessIdentity(
            pid: Int32.max,
            startSeconds: 1,
            startMicroseconds: 1
        )
        try ownerScope.recoveryStore.save(committedRecord.preparing(
            replacement: committedSnapshot.adopting(
                ownershipToken: pendingToken,
                ownerProcessIdentity: deadOwner
            ),
            ownershipToken: pendingToken,
            ownerProcessIdentity: deadOwner
        ))
        let recoveryCommands = LocationLifecycleCommandRunner()
        let recoveryService = SimulatorControlService(
            commands: recoveryCommands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )

        #expect(await recoveryService.recoverOrphanedLocationRoutes())
        #expect(await recoveryCommands.arguments().isEmpty)
        let recoveredRecord = try #require(
            try ownerScope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        #expect(recoveredRecord.pending == nil)
        #expect(recoveredRecord.committed == committedSnapshot)
        try await ownerService.stopLocationRoute(deviceID: deviceID)
    }

    @Test("Recovery rolls back a published pending route to its live owner")
    func recoveryRollsBackPublishedPendingRoute() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-published-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerScope = SimulatorLocationOwnershipScope(directory: directory)
        let ownerService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: ownerScope
        )
        try await ownerService.startLocationRoute(deviceID: deviceID, route: Self.route())
        let committedRecord = try #require(
            try ownerScope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        let committedSnapshot = try #require(committedRecord.committed)
        let pendingToken = UUID()
        let deadOwner = SimulatorProcessIdentity(
            pid: Int32.max,
            startSeconds: 1,
            startMicroseconds: 1
        )
        try ownerScope.recoveryStore.save(committedRecord.preparing(
            replacement: committedSnapshot.adopting(
                ownershipToken: pendingToken,
                ownerProcessIdentity: deadOwner
            ),
            ownershipToken: pendingToken,
            ownerProcessIdentity: deadOwner
        ))
        let failedReplacementScope = SimulatorLocationOwnershipScope(directory: directory)
        try await failedReplacementScope.registry.claim(
            pendingToken,
            deviceIdentifier: deviceID
        )
        let recoveryCommands = LocationLifecycleCommandRunner()
        let recoveryService = SimulatorControlService(
            commands: recoveryCommands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )

        #expect(await recoveryService.recoverOrphanedLocationRoutes())
        let arguments = await recoveryCommands.arguments()
        #expect(arguments.first == ["simctl", "location", deviceID, "clear"])
        #expect(arguments.last?.prefix(4) == ["simctl", "location", deviceID, "start"])
        let recoveredRecord = try #require(
            try ownerScope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        #expect(recoveredRecord.pending == nil)
        #expect(recoveredRecord.committed == committedSnapshot)
        try await ownerService.stopLocationRoute(deviceID: deviceID)
    }

    @Test("A later mutation recovers an abandoned live-process transaction")
    func laterMutationRecoversAbandonedLiveTransaction() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-live-pending-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ownerScope = SimulatorLocationOwnershipScope(directory: directory)
        let ownerService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: ownerScope
        )
        try await ownerService.startLocationRoute(deviceID: deviceID, route: Self.route())
        let committedRecord = try #require(
            try ownerScope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        let committedSnapshot = try #require(committedRecord.committed)
        let pendingToken = UUID()
        let liveOwner = try #require(SimulatorProcessIdentity.current)
        try ownerScope.recoveryStore.save(committedRecord.preparing(
            replacement: committedSnapshot.adopting(
                ownershipToken: pendingToken,
                ownerProcessIdentity: liveOwner
            ),
            ownershipToken: pendingToken,
            ownerProcessIdentity: liveOwner
        ))
        let failedReplacementScope = SimulatorLocationOwnershipScope(directory: directory)
        try await failedReplacementScope.registry.claim(
            pendingToken,
            deviceIdentifier: deviceID
        )
        let replacementCommands = LocationLifecycleCommandRunner()
        let replacementService = SimulatorControlService(
            commands: replacementCommands,
            locationOwnershipScope: SimulatorLocationOwnershipScope(directory: directory)
        )

        try await replacementService.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )

        let arguments = await replacementCommands.arguments()
        #expect(arguments.first == ["simctl", "location", deviceID, "clear"])
        #expect(arguments.dropFirst().first?.prefix(4) == [
            "simctl", "location", deviceID, "start",
        ])
        #expect(arguments.last == [
            "simctl", "location", deviceID, "set", "40.0,-73.0",
        ])
        #expect(try ownerScope.recoveryStore.record(deviceIdentifier: deviceID) == nil)
    }

    @Test("A stale pane cannot adopt another pane's recovered route token")
    func stalePaneCannotAdoptRecoveredRouteToken() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-stale-pane-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = SimulatorLocationOwnershipScope(directory: directory)
        let staleCommands = LocationLifecycleCommandRunner()
        let staleService = SimulatorControlService(
            commands: staleCommands,
            locationOwnershipScope: scope
        )
        let currentService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )
        try await staleService.startLocationRoute(deviceID: deviceID, route: Self.route())
        let currentRoute = SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 34.0, longitude: -118.2),
                SimulatorLocationCoordinate(latitude: 34.1, longitude: -118.1),
            ],
            speed: 5
        )
        try await currentService.startLocationRoute(deviceID: deviceID, route: currentRoute)
        let committedRecord = try #require(
            try scope.recoveryStore.record(deviceIdentifier: deviceID)
        )
        let committedSnapshot = try #require(committedRecord.committed)
        let pendingToken = UUID()
        let liveOwner = try #require(SimulatorProcessIdentity.current)
        try scope.recoveryStore.save(committedRecord.preparing(
            replacement: committedSnapshot.adopting(
                ownershipToken: pendingToken,
                ownerProcessIdentity: liveOwner
            ),
            ownershipToken: pendingToken,
            ownerProcessIdentity: liveOwner
        ))
        try await scope.registry.claim(pendingToken, deviceIdentifier: deviceID)

        do {
            try await staleService.pauseLocationRoute(deviceID: deviceID)
            Issue.record("Expected the stale pane to retain its superseded token")
        } catch let error as SimulatorControlError {
            #expect(error.code == "location_route_ownership_lost")
        }

        let arguments = await staleCommands.arguments()
        #expect(arguments.count == 3)
        #expect(arguments[0].prefix(4) == ["simctl", "location", deviceID, "start"])
        #expect(arguments[1] == ["simctl", "location", deviceID, "clear"])
        #expect(arguments[2].prefix(4) == ["simctl", "location", deviceID, "start"])
        #expect(await staleService.activeLocationRoutes[deviceID] == nil)
        try await currentService.stopLocationRoute(deviceID: deviceID)
    }

    @Test("Launch recovery decodes the previous location journal schema")
    func launchRecoveryDecodesPreviousLocationJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-legacy-schema-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = SimulatorLocationOwnershipScope(directory: directory)
        let deviceID = UUID().uuidString
        let route = Self.route()
        let legacyRecord = LegacyLocationRouteRecoveryRecord(
            deviceIdentifier: deviceID,
            initialCoordinate: route.waypoints[0],
            state: .running(route: route, startedAt: Date()),
            ownershipToken: UUID(),
            ownerProcessIdentity: SimulatorProcessIdentity(
                pid: Int32.max,
                startSeconds: 1,
                startMicroseconds: 1
            )
        )
        try scope.recoveryStore.save(SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: deviceID,
            initialCoordinate: legacyRecord.initialCoordinate,
            state: legacyRecord.state,
            ownershipToken: legacyRecord.ownershipToken,
            ownerProcessIdentity: legacyRecord.ownerProcessIdentity
        ))
        let journalDirectory = directory.appendingPathComponent(
            "location-routes",
            isDirectory: true
        )
        let journalURL = try #require(try FileManager.default.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: nil
        ).first { $0.pathExtension == "json" })
        try JSONEncoder().encode(legacyRecord).write(to: journalURL, options: .atomic)
        let commands = LocationLifecycleCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: scope
        )

        #expect(await service.recoverOrphanedLocationRoutes())
        #expect(await commands.arguments() == [
            ["simctl", "location", deviceID, "clear"],
            ["simctl", "location", deviceID, "set", "37.7,-122.4"],
        ])
        #expect(try scope.recoveryStore.record(deviceIdentifier: deviceID) == nil)
    }

    @Test("Launch recovery restores dead route owners and preserves live owners")
    func launchRecoveryRestoresOnlyOrphanedRoutes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-launch-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = SimulatorLocationOwnershipScope(directory: directory)
        let route = Self.route()
        let orphanDeviceID = "ORPHAN-\(UUID().uuidString)"
        let liveDeviceID = "LIVE-\(UUID().uuidString)"
        let orphanToken = UUID()
        let liveToken = UUID()
        try scope.recoveryStore.save(SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: orphanDeviceID,
            initialCoordinate: route.waypoints[0],
            state: .running(route: route, startedAt: Date()),
            ownershipToken: orphanToken,
            ownerProcessIdentity: SimulatorProcessIdentity(
                pid: Int32.max,
                startSeconds: 1,
                startMicroseconds: 1
            )
        ))
        try scope.recoveryStore.save(SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: liveDeviceID,
            initialCoordinate: route.waypoints[0],
            state: .running(route: route, startedAt: Date()),
            ownershipToken: liveToken,
            ownerProcessIdentity: try #require(SimulatorProcessIdentity.current)
        ))
        let commands = LocationLifecycleCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: scope
        )

        #expect(await service.recoverOrphanedLocationRoutes())

        #expect(await commands.arguments() == [
            ["simctl", "location", orphanDeviceID, "clear"],
            ["simctl", "location", orphanDeviceID, "set", "37.7,-122.4"],
        ])
        #expect(try scope.recoveryStore.record(deviceIdentifier: orphanDeviceID) == nil)
        #expect(
            try scope.recoveryStore.record(deviceIdentifier: liveDeviceID)?
                .committed?.ownershipToken == liveToken
        )
    }

    @Test("Launch recovery fails closed on a corrupt location journal")
    func launchRecoveryFailsClosedOnCorruptLocationJournal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-corrupt-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = SimulatorLocationOwnershipScope(directory: directory)
        let recoverableDeviceID = "RECOVERABLE-\(UUID().uuidString)"
        let route = Self.route()
        try scope.recoveryStore.save(SimulatorLocationRouteRecoveryRecord(
            deviceIdentifier: recoverableDeviceID,
            initialCoordinate: route.waypoints[0],
            state: .running(route: route, startedAt: Date()),
            ownershipToken: UUID(),
            ownerProcessIdentity: SimulatorProcessIdentity(
                pid: Int32.max,
                startSeconds: 1,
                startMicroseconds: 1
            )
        ))
        let journalDirectory = directory.appendingPathComponent(
            "location-routes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: journalDirectory,
            withIntermediateDirectories: true
        )
        let corruptJournal = journalDirectory.appendingPathComponent("corrupt.json")
        try Data(#"{"deviceIdentifier":"DEVICE""#.utf8).write(to: corruptJournal)
        let commands = LocationLifecycleCommandRunner()
        let service = SimulatorControlService(
            commands: commands,
            locationOwnershipScope: scope
        )

        #expect(!(await service.recoverOrphanedLocationRoutes()))
        #expect(await commands.arguments() == [
            ["simctl", "location", recoverableDeviceID, "clear"],
            ["simctl", "location", recoverableDeviceID, "set", "37.7,-122.4"],
        ])
        #expect(try scope.recoveryStore.record(deviceIdentifier: recoverableDeviceID) == nil)
        #expect(!FileManager.default.fileExists(atPath: corruptJournal.path))
        let quarantinedJournals = try FileManager.default.contentsOfDirectory(
            at: journalDirectory.appendingPathComponent("quarantine", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(quarantinedJournals.count == 1)
        #expect(
            quarantinedJournals[0].lastPathComponent.hasPrefix("corrupt.json.corrupt-")
        )
    }

    @Test("A fixed location removes the route recovery journal")
    func fixedLocationSupersedesRouteJournal() async throws {
        let deviceID = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "location-fixed-recovery-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = SimulatorLocationOwnershipScope(directory: directory)
        let service = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )
        try await service.startLocationRoute(deviceID: deviceID, route: Self.route())
        try await service.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )

        #expect(try scope.recoveryStore.record(deviceIdentifier: deviceID) == nil)
    }

    @Test(
        "Failed pause and stop commands preserve their running route lifecycle",
        arguments: [1, 2]
    )
    func failedPauseAndStopPreserveLifecycle(failureInvocationIndex: Int) async throws {
        for operation in [LocationRouteMutation.pause, .stop] {
            let commands = LocationLifecycleCommandRunner(
                failureInvocationIndices: [failureInvocationIndex]
            )
            let service = SimulatorControlService(
                commands: commands,
                locationOwnershipScope: SimulatorLocationOwnershipScope()
            )
            let route = Self.route()
            try await service.startLocationRoute(deviceID: "DEVICE", route: route)

            do {
                switch operation {
                case .pause:
                    try await service.pauseLocationRoute(deviceID: "DEVICE")
                case .stop:
                    try await service.stopLocationRoute(deviceID: "DEVICE")
                }
                Issue.record("Expected the injected location command failure")
            } catch {}

            guard case .running? = await service.activeLocationRoutes["DEVICE"] else {
                Issue.record("The failed \(operation) discarded the running route")
                continue
            }
            #expect(await service.locationRouteTokens["DEVICE"] != nil)
            #expect(await service.locationLifecycleTasks["DEVICE"] != nil)
            let arguments = await commands.arguments()
            if failureInvocationIndex == 2 {
                #expect(arguments.last?.prefix(4) == ["simctl", "location", "DEVICE", "start"])
            } else {
                #expect(arguments.count == 2)
            }
        }
    }

    @Test("A newer client prevents an older looping route from replaying")
    func newerClientOwnsLocationMutation() async throws {
        let deviceID = UUID().uuidString
        let scope = SimulatorLocationOwnershipScope()
        let oldCommands = LocationLifecycleCommandRunner()
        let oldSleeper = LocationLifecycleSleepGate()
        let oldService = SimulatorControlService(
            commands: oldCommands,
            locationOwnershipScope: scope,
            routeSleep: { duration in try await oldSleeper.sleep(for: duration) }
        )
        let newCommands = LocationLifecycleCommandRunner()
        let newService = SimulatorControlService(
            commands: newCommands,
            locationOwnershipScope: scope
        )
        let baseRoute = Self.route()
        let loop = SimulatorLocationRoute(
            waypoints: baseRoute.waypoints,
            speed: baseRoute.speed,
            updateDistance: baseRoute.updateDistance,
            updateInterval: baseRoute.updateInterval,
            loops: true
        )

        try await oldService.startLocationRoute(deviceID: deviceID, route: loop)
        await oldSleeper.waitForStartCount(1)
        try await newService.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )
        await oldSleeper.advance()
        await eventually {
            await oldService.activeLocationRoutes[deviceID] == nil
        }

        #expect(await oldCommands.arguments().count == 1)
        #expect(await newCommands.arguments() == [
            ["simctl", "location", deviceID, "set", "40.0,-73.0"],
        ])
        #expect(await oldService.activeLocationRoutes[deviceID] == nil)
        #expect(await oldService.locationRouteInitialCoordinates[deviceID] == nil)
        #expect(await oldService.locationRouteTokens[deviceID] == nil)
    }

    @Test("Losing route ownership reports failure and clears stale local state")
    func lostOwnershipFailsPause() async throws {
        let deviceID = UUID().uuidString
        let scope = SimulatorLocationOwnershipScope()
        let oldService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )
        let newService = SimulatorControlService(
            commands: LocationLifecycleCommandRunner(),
            locationOwnershipScope: scope
        )

        try await oldService.startLocationRoute(deviceID: deviceID, route: Self.route())
        try await newService.setLocation(
            deviceID: deviceID,
            coordinate: SimulatorLocationCoordinate(latitude: 40, longitude: -73)
        )

        do {
            try await oldService.pauseLocationRoute(deviceID: deviceID)
            Issue.record("Expected lost location ownership to fail explicitly")
        } catch let error as SimulatorControlError {
            #expect(error.code == "location_route_ownership_lost")
        }
        #expect(await oldService.activeLocationRoutes[deviceID] == nil)
        #expect(await oldService.locationRouteInitialCoordinates[deviceID] == nil)
        #expect(await oldService.locationRouteTokens[deviceID] == nil)
    }

    private static func route() -> SimulatorLocationRoute {
        SimulatorLocationRoute(
            waypoints: [
                SimulatorLocationCoordinate(latitude: 37.7, longitude: -122.4),
                SimulatorLocationCoordinate(latitude: 37.71, longitude: -122.39),
            ],
            speed: 3
        )
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition did not become true")
    }
}
