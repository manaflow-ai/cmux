import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Worker factories share camera cleanup only through an injected app scope")
    func workerFactoryCameraCleanupScopeIsInjected() async {
        let appScope = SimulatorCameraCleanupOwnershipScope()
        let first = SimulatorWorkerClientFactory(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            cameraCleanupOwnershipScope: appScope
        ).makeClient(simulatorControl: TestSimulatorControl())
        let second = SimulatorWorkerClientFactory(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            cameraCleanupOwnershipScope: appScope
        ).makeClient(simulatorControl: TestSimulatorControl())
        let independent = SimulatorWorkerClientFactory(
            executableURL: URL(fileURLWithPath: "/fake/cmux")
        ).makeClient(simulatorControl: TestSimulatorControl())
        let firstCoordinator = await first.cameraCleanupCoordinator
        let secondCoordinator = await second.cameraCleanupCoordinator
        let independentCoordinator = await independent.cameraCleanupCoordinator

        #expect(firstCoordinator === secondCoordinator)
        #expect(firstCoordinator !== independentCoordinator)
    }

    @Test("Completed camera cleanup prunes per-target ownership state")
    func completedCameraCleanupPrunesTargetState() async throws {
        let scope = SimulatorCameraCleanupOwnershipScope()
        let coordinator = scope.coordinator
        let deviceIdentifier = "DEVICE-\(UUID().uuidString)"
        let bundleIdentifier = "com.example.camera"
        _ = try await coordinator.claim(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        #expect(await coordinator.trackedTargetCount == 1)

        let cleanup = await coordinator.enqueue(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: [bundleIdentifier]
        ) {
            .completed
        }
        #expect(await cleanup.value == .completed)

        for _ in 0..<1_000 {
            if await coordinator.trackedTargetCount == 0 { break }
            await Task.yield()
        }
        #expect(await coordinator.trackedTargetCount == 0)
    }

    @Test("Camera cleanup for one Simulator does not block another Simulator")
    func unrelatedCameraCleanupRunsConcurrently() async throws {
        let coordinator = SimulatorCameraCleanupCoordinator()
        let control = BlockingCameraCleanupControl()
        let firstDevice = "DEVICE-A"
        let firstBundle = "com.example.a"
        let firstOwner = try await coordinator.claim(
            deviceIdentifier: firstDevice,
            bundleIdentifier: firstBundle
        )
        let cleanup = await coordinator.enqueue(
            deviceIdentifier: firstDevice,
            bundleIdentifiers: [firstBundle]
        ) {
            await cleanSimulatorCameraInjections(
                deviceIdentifier: firstDevice,
                bundleIdentifiers: [firstBundle],
                simulatorControl: control,
                ownershipTokens: [firstBundle: firstOwner],
                cleanupCoordinator: coordinator
            )
        }
        for _ in 0..<1_000 {
            if await control.isBlocked { break }
            await Task.yield()
        }
        #expect(await control.isBlocked)

        _ = try await coordinator.claim(
            deviceIdentifier: "DEVICE-B",
            bundleIdentifier: "com.example.b"
        )

        await control.release()
        #expect(await cleanup.value == .completed)
    }

    @Test("Camera cleanup returns a typed failure when relaunch fails")
    func cameraCleanupReturnsTypedFailure() async throws {
        let coordinator = SimulatorCameraCleanupCoordinator()
        let control = FailingCameraCleanupControl()
        let deviceIdentifier = "DEVICE-\(UUID().uuidString)"
        let bundleIdentifier = "com.example.camera"
        let owner = try await coordinator.claim(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )

        let result = await cleanSimulatorCameraInjections(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: [bundleIdentifier],
            simulatorControl: control,
            ownershipTokens: [bundleIdentifier: owner],
            cleanupCoordinator: coordinator
        )

        #expect(result == .failed(SimulatorFailure(
            code: "fixture_cleanup_failed",
            message: "The fixture relaunch failed.",
            isRecoverable: true
        )))
    }

    @Test("A newer camera owner waits until older cleanup finishes mutating its app")
    func newerCameraOwnerWaitsForCleanup() async throws {
        let coordinator = SimulatorCameraCleanupCoordinator()
        let control = BlockingCameraCleanupControl()
        let deviceIdentifier = UUID().uuidString
        let bundleIdentifier = "com.example.camera"
        let oldOwner = try await coordinator.claim(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifier: bundleIdentifier
        )
        let cleanup = await coordinator.enqueue(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: [bundleIdentifier]
        ) {
            await cleanSimulatorCameraInjections(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifiers: [bundleIdentifier],
                simulatorControl: control,
                ownershipTokens: [bundleIdentifier: oldOwner],
                cleanupCoordinator: coordinator
            )
        }
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline, !(await control.isBlocked) {
            try? await ContinuousClock().sleep(for: .milliseconds(1))
        }
        #expect(await control.isBlocked)

        let newClaim = Task {
            try await coordinator.claim(
                deviceIdentifier: deviceIdentifier,
                bundleIdentifier: bundleIdentifier
            )
        }
        for _ in 0..<100 { await Task.yield() }
        let actionCountBeforeRelease = await control.actions.count
        #expect(actionCountBeforeRelease == 1, "Observed \(actionCountBeforeRelease) cleanup actions")
        await control.release()
        #expect(await cleanup.value == .completed)
        _ = try await newClaim.value

        #expect(cameraCleanupActionsMatch(await control.actions,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: [bundleIdentifier]
        ))
    }

    @Test("An unattached replacement client ignores cleanup for another target")
    func replacementClientIgnoresUnrelatedCameraCleanup() async throws {
        let cleanupCoordinator = SimulatorCameraCleanupCoordinator()
        let gate = BlockingCameraCleanupControl()
        let cleanup = await cleanupCoordinator.enqueue(
            deviceIdentifier: "blocked-cleanup",
            bundleIdentifiers: ["com.example.camera"]
        ) {
            _ = try? await gate.perform(.terminateApplication(
                deviceID: "blocked-cleanup",
                bundleIdentifier: "com.example.camera"
            ))
            return .completed
        }
        for _ in 0..<1_000 {
            if await gate.isBlocked { break }
            await Task.yield()
        }
        let client = SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            arguments: [SimulatorWorkerClient.workerModeArgument],
            environment: [:],
            ackTimeout: .seconds(60),
            simulatorControl: TestSimulatorControl(),
            launcher: TestWorkerLauncher(),
            sleeper: ImmediateWorkerSleeper(),
            cameraCleanupCoordinator: cleanupCoordinator
        )

        #expect(await client.waitForCameraCleanup())

        await gate.release()
        #expect(await cleanup.value == .completed)
        await client.stop()
    }

    @Test("A second worker crash cleans camera targets before explicit recovery")
    func cameraFuseCleanupPrecedesRecovery() async throws {
        let deviceIdentifier = "CAMERA-\(UUID().uuidString)"
        let processIdentifiers: [Int32] = [41_001, 41_002, 41_003]
        let launcher = TestWorkerLauncher(processIdentifiers: processIdentifiers)
        let control = BlockingCameraCleanupControl()
        let client = makeClient(launcher: launcher, control: control)
        await client.send(.attach(udid: deviceIdentifier, geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        first.emit(.status(.streaming))
        first.emit(.capabilities([.cameraInjection]))
        first.emit(.frameTransport(simulatorFrameTransportDescriptor(77)))
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        first.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(first)
        for bundleIdentifier in ["com.example.a", "com.example.b"] {
            _ = try await client.perform(.configureCamera(.targeted(
                bundleIdentifier: bundleIdentifier,
                source: .placeholder
            )))
        }

        let firstRegion = try TestCameraSharedMemoryRegion(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifiers[0]
        )
        first.finish()
        let second = try await endpoint(from: launcher, at: 1)
        second.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: configuration.targetBundleIdentifier != "com.example.b",
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            default:
                return nil
            }
        }
        second.emit(.status(.streaming))
        #expect(!firstRegion.exists())
        #expect((await control.actions).isEmpty)
        let secondMessages = try #require(await second.waitForInboundMessages { messages in
            messages.filter {
                if case .configureCamera = $0 { return true }
                return false
            }.count == 2
        })
        let replayMessages = secondMessages.filter {
            if case .configureCamera = $0 { return true }
            return false
        }
        #expect(replayMessages.count == 2)
        for _ in 0..<1_000 {
            if await client.cameraReplayConfigurations.count == 1 { break }
            await Task.yield()
        }
        #expect(await client.cameraReplayConfigurations.compactMap(\.targetBundleIdentifier)
            == ["com.example.a"])

        let secondRegion = try TestCameraSharedMemoryRegion(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifiers[1]
        )
        second.finish()
        for _ in 0..<1_000 {
            if await control.isBlocked { break }
            await Task.yield()
        }
        #expect(await control.isBlocked)
        #expect(!secondRegion.exists())

        let recovery = Task { try await client.recover() }
        for _ in 0..<100 { await Task.yield() }
        #expect(launcher.endpoint(at: 2) == nil)
        await control.release()
        try await recovery.value

        #expect(cameraCleanupActionsMatch(
            await control.actions,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: ["com.example.a", "com.example.b"]
        ))
        let third = try #require(launcher.endpoint(at: 2))
        third.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            default:
                return nil
            }
        }
        third.emit(.status(.streaming))
        let thirdMessages = try #require(await third.waitForInboundMessages { messages in
            messages.contains(where: {
                guard case .configureCamera = $0 else { return false }
                return true
            })
        })
        let replayTargets = Set(thirdMessages.compactMap { message -> String? in
            guard case let .configureCamera(_, configuration) = message else { return nil }
            return configuration.targetBundleIdentifier
        })
        #expect(replayTargets == ["com.example.a"])
        await client.stop()
    }

    @Test("Closing a camera client relaunches clean targets and unlinks worker memory")
    func cameraCleanupOnClose() async throws {
        let deviceIdentifier = "CAMERA-\(UUID().uuidString)"
        let processIdentifier: Int32 = 42_001
        let launcher = TestWorkerLauncher(processIdentifiers: [processIdentifier])
        let control = TestSimulatorControl()
        let client = makeClient(launcher: launcher, control: control)
        await client.send(.attach(udid: deviceIdentifier, geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(78)))
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        endpoint.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(endpoint)
        _ = try await client.perform(.configureCamera(.targeted(
            bundleIdentifier: "com.example.camera",
            source: .placeholder
        )))
        let region = try TestCameraSharedMemoryRegion(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        )

        await client.stop()

        #expect(!region.exists())
        #expect(cameraCleanupActionsMatch(await control.actions,
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: ["com.example.camera"]
        ))
        #expect(endpoint.terminationCountValue() == 1)
        #expect(endpoint.inboundMessages().contains(.releaseInputs))
        #expect(endpoint.inboundMessages().contains(.shutdown))
        #expect(launcher.endpoint(at: 1) == nil)
    }

    @Test("An explicit camera target is cleanup-owned before worker confirmation")
    func pendingExplicitCameraTargetIsCleanupOwned() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        for _ in 0..<100 { await Task.yield() }
        let requestID = UUID()

        try await client.sendRequired(.configureCamera(
            requestID: requestID,
            configuration: .targeted(
                bundleIdentifier: "com.example.pending",
                source: .placeholder
            )
        ))

        #expect(await client.cameraCleanupSnapshot().bundleIdentifiers == ["com.example.pending"])
        await client.stop()
    }

    @Test("Camera configuration stops when cleanup ownership cannot be published")
    func failedCameraOwnershipPreventsConfiguration() async throws {
        let blockingFile = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-camera-ownership-test-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: blockingFile) }
        try Data().write(to: blockingFile)
        let cleanupCoordinator = SimulatorCameraCleanupCoordinator(
            ownershipStore: SimulatorCrossProcessOwnershipStore(
                directory: blockingFile.appendingPathComponent(
                    "ownership",
                    isDirectory: true
                )
            )
        )
        let launcher = TestWorkerLauncher()
        let client = makeClient(
            launcher: launcher,
            cameraCleanupCoordinator: cleanupCoordinator
        )
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil), probe: false)
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.status(.streaming))
        for _ in 0..<1_000 {
            if await client.currentStatus == .streaming { break }
            await Task.yield()
        }
        #expect(await client.currentStatus == .streaming)

        await #expect(throws: CocoaError.self) {
            try await client.sendRequired(.configureCamera(
                requestID: UUID(),
                configuration: .targeted(
                    bundleIdentifier: "com.example.camera",
                    source: .placeholder
                )
            ), probe: false)
        }

        #expect(!endpoint.inboundMessages().contains {
            if case .configureCamera = $0 { return true }
            return false
        })
        #expect(await client.cameraCleanupSnapshot().bundleIdentifiers.isEmpty)
        await client.stop()
    }

    @Test("A resolved inferred camera target is cleanup-owned before injection")
    func resolvedInferredCameraTargetIsCleanupOwned() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        try await client.sendRequired(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        for _ in 0..<100 { await Task.yield() }
        let requestID = UUID()
        try await client.sendRequired(.configureCamera(
            requestID: requestID,
            configuration: .placeholder
        ))

        endpoint.emit(.cameraTargetResolved(
            requestID: requestID,
            bundleIdentifier: "com.example.inferred"
        ))
        for _ in 0..<10_000 {
            if await client.cameraCleanupSnapshot().bundleIdentifiers
                .contains("com.example.inferred") { break }
            await Task.yield()
        }

        #expect(await client.cameraCleanupSnapshot().bundleIdentifiers == ["com.example.inferred"])
        await client.stop()
    }

    private func endpoint(
        from launcher: TestWorkerLauncher,
        at index: Int
    ) async throws -> TestWorkerEndpoint {
        if let endpoint = await launcher.waitForEndpoint(at: index) { return endpoint }
        throw SimulatorControlError(
            code: "missing_test_worker",
            arguments: [],
            message: "The expected test worker did not launch."
        )
    }

    private func cameraCleanupActionsMatch(
        _ actions: [SimulatorControlAction],
        deviceIdentifier: String,
        bundleIdentifiers: [String]
    ) -> Bool {
        guard actions.count == bundleIdentifiers.count else { return false }
        return zip(actions, bundleIdentifiers.sorted()).allSatisfy { action, bundleIdentifier in
            guard case let .cleanupCameraApplication(deviceID, target, _) = action else {
                return false
            }
            return deviceID == deviceIdentifier && target == bundleIdentifier
        }
    }
}

private func acknowledgeRecordedPings(_ endpoint: TestWorkerEndpoint) {
    for sequence in endpoint.inboundMessages().compactMap({ message -> UInt64? in
        guard case let .ping(sequence) = message else { return nil }
        return sequence
    }) {
        endpoint.emit(.ack(sequence))
    }
}

private actor FailingCameraCleanupControl: SimulatorControlling {
    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        throw SimulatorFailure(
            code: "fixture_cleanup_failed",
            message: "The fixture relaunch failed.",
            isRecoverable: true
        )
    }
}
