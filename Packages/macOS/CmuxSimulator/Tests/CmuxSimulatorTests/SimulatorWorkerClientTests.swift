import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator worker client")
struct SimulatorWorkerClientTests {
    @Test("Privacy snapshots decode older workers without application rows")
    func privacySnapshotVersionSkew() throws {
        let snapshot = SimulatorPrivacySnapshot(
            deviceID: "DEVICE",
            bundleIdentifier: nil,
            authorizations: [.camera: .granted]
        )
        let encoded = try JSONEncoder().encode(snapshot)
        var legacy = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy.removeValue(forKey: "applications")
        legacy.removeValue(forKey: "isTruncated")

        let decoded = try JSONDecoder().decode(
            SimulatorPrivacySnapshot.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.applications.isEmpty)
        #expect(!decoded.isTruncated)
        #expect(decoded.authorizations[.camera] == .granted)
    }

    @Test("Foreground app metadata preserves executable and bundle path")
    func foregroundApplicationMetadataRoundTrip() throws {
        let application = SimulatorApplicationInfo(
            bundleIdentifier: "com.example.App",
            processIdentifier: 42,
            name: "Example",
            version: "1.2",
            build: "34",
            minimumOSVersion: "18.0",
            isReactNative: true,
            executable: "Example",
            bundlePath: "/tmp/Example.app"
        )

        let decoded = try JSONDecoder().decode(
            SimulatorApplicationInfo.self,
            from: JSONEncoder().encode(application)
        )
        #expect(decoded == application)
    }

    @Test("Attachment defers its responsiveness ping until streaming")
    func attachmentDefersPingUntilStreaming() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        let geometry = SimulatorSurfaceGeometry(width: 800, height: 600, scale: 2)

        await client.send(.attach(udid: "DEVICE", geometry: geometry))
        await client.send(.resize(geometry))

        let endpoint = try #require(launcher.endpoint(at: 0))
        var messages = endpoint.inboundMessages()
        #expect(messages.first == .attach(udid: "DEVICE", geometry: geometry))
        #expect(!messages.contains { if case .ping = $0 { true } else { false } })

        endpoint.emit(.status(.streaming))
        #expect(await iterator.next() == .message(.status(.streaming)))
        for _ in 0..<10_000 {
            messages = endpoint.inboundMessages()
            if messages.contains(where: { if case .ping = $0 { true } else { false } }) {
                break
            }
            await Task.yield()
        }
        #expect(messages.contains { if case .ping = $0 { true } else { false } })
        await client.stop()
    }

    @Test("A pending text sequence defers probes until its correlated completion")
    func textInputDefersResponsivenessProbe() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let requestIdentifier = UUID()
        let sequence = try SimulatorUSKeyboardTextEncoder.encode("a")

        let inputTask = Task {
            await client.send(.typeText(requestID: requestIdentifier, sequence: sequence))
        }
        var launchedEndpoint: TestWorkerEndpoint?
        for _ in 0..<10_000 {
            launchedEndpoint = launcher.endpoint(at: 0)
            if launchedEndpoint?.inboundMessages().contains(where: {
                if case .typeText = $0 { true } else { false }
            }) == true { break }
            await Task.yield()
        }
        let endpoint = try #require(launchedEndpoint)

        await client.send(.resize(SimulatorSurfaceGeometry(width: 700, height: 500, scale: 2)))
        #expect(!endpoint.inboundMessages().contains {
            if case .ping = $0 { true } else { false }
        })

        endpoint.emit(.textInput(requestID: requestIdentifier, succeeded: true))
        await inputTask.value
        var messages: [SimulatorWorkerInbound] = []
        for _ in 0..<10_000 {
            messages = endpoint.inboundMessages()
            if messages.contains(where: { if case .ping = $0 { true } else { false } }) {
                break
            }
            await Task.yield()
        }
        #expect(messages.contains { if case .ping = $0 { true } else { false } })
        await client.stop()
    }

    @Test("One crash restarts and a second crash trips a recoverable fuse")
    func crashFuseAndRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))

        let first = try #require(launcher.endpoint(at: 0))
        first.finish()
        #expect(await iterator.next() == .workerStopped)
        let second = try #require(launcher.endpoint(at: 1))

        second.finish()
        #expect(await iterator.next() == .workerStopped)
        guard case let .message(.failure(failure)) = await iterator.next() else {
            Issue.record("Expected a crash-fuse failure")
            return
        }
        #expect(failure.code == "worker_crash_fuse")

        try await client.recover()
        #expect(launcher.endpoint(at: 2) != nil)
        await client.stop()
    }

    @Test("Traffic arriving behind a pending ping gets a second ordered proof")
    func reprobesCommandsQueuedBehindPing() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        await client.send(.resize(SimulatorSurfaceGeometry(width: 700, height: 500, scale: 2)))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let beforeAcknowledgement = endpoint.inboundMessages()
        let firstPing = try #require(beforeAcknowledgement.compactMap { message -> UInt64? in
            if case let .ping(sequence) = message { return sequence }
            return nil
        }.first)

        endpoint.emit(.ack(firstPing))
        endpoint.emit(.context(77))
        #expect(await iterator.next() == .message(.context(77)))

        let pings = endpoint.inboundMessages().compactMap { message -> UInt64? in
            if case let .ping(sequence) = message { return sequence }
            return nil
        }
        #expect(pings.count == 2)
        #expect(pings[1] > pings[0])
        await client.stop()
    }

    @Test("Stopping releases input and worker state without shutting down the device")
    func stopsWorkerWithoutDeviceShutdown() async throws {
        let launcher = TestWorkerLauncher()
        let control = TestSimulatorControl()
        let client = makeClient(launcher: launcher, control: control)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))

        await client.stop()

        let messages = endpoint.inboundMessages()
        #expect(messages.contains(.releaseInputs))
        #expect(messages.contains(.shutdown))
        #expect(await control.shutdownDeviceIDs.isEmpty)
    }

    @Test("Activation boots and waits before attach; shutdown releases the same session")
    func activatesAndShutsDownDevice() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            guard case .attach = message else { return nil }
            return .status(.streaming)
        }
        let control = TestSimulatorControl()
        let client = makeClient(launcher: launcher, control: control)

        try await client.activateDevice(id: "DEVICE", geometry: nil)
        #expect(await control.bootDeviceIDs == ["DEVICE"])
        #expect(await control.waitDeviceIDs == ["DEVICE"])
        let endpoint = try #require(launcher.endpoint(at: 0))
        #expect(endpoint.inboundMessages().contains(.attach(udid: "DEVICE", geometry: nil)))

        try await client.shutdownDevice(id: "DEVICE")
        #expect(await control.shutdownDeviceIDs == ["DEVICE"])
        #expect(endpoint.inboundMessages().contains(.releaseInputs))
        #expect(endpoint.inboundMessages().contains(.shutdown))
    }

    @Test("Activation skips bootstatus for a device already reported booted")
    func activatesAlreadyBootedDeviceWithoutWaitingAgain() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            guard case .attach = message else { return nil }
            return .status(.streaming)
        }
        let control = TestSimulatorControl(devices: [SimulatorDevice(
            id: "DEVICE",
            name: "iPhone 17 Pro",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
            runtimeName: "iOS 26.5",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
            family: .iPhone,
            state: .booted,
            isAvailable: true,
            lastBootedAt: nil
        )])
        let client = makeClient(launcher: launcher, control: control)

        try await client.activateDevice(id: "DEVICE", geometry: nil)

        #expect(await control.bootDeviceIDs == ["DEVICE"])
        #expect(await control.waitDeviceIDs.isEmpty)
        await client.stop()
    }

    @Test("Camera configuration is rejected before host-side private loading")
    func rejectsUnavailableCameraAdapter() async {
        let client = makeClient(launcher: TestWorkerLauncher())

        do {
            _ = try await client.perform(.configureCamera(.image(URL(fileURLWithPath: "/tmp/frame.png"))))
            Issue.record("Expected camera capability failure")
        } catch let error as SimulatorControlError {
            #expect(error.code == "camera_injection_unavailable")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        await client.stop()
    }

    @Test("Camera configuration waits for the correlated worker result")
    func correlatesCameraConfiguration() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.capabilities([.cameraInjection]))
        endpoint.emit(.context(55))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .configureCamera(requestID, .placeholder) = message else { return nil }
            return .cameraConfiguration(
                requestID: requestID,
                succeeded: true,
                targetBundleIdentifier: "com.example.camera"
            )
        }

        let result = try await client.perform(.configureCamera(.placeholder))

        #expect(result == .none)
        await client.stop()
    }

    @Test("Camera permission routes only through the capability-gated private adapter")
    func routesExtendedPermissionToWorker() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.capabilities([.extendedPermissions]))
        endpoint.emit(.context(88))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .setPrivatePrivacy(requestID, _, _, _, _) = message else { return nil }
            return .privatePrivacy(requestID: requestID, succeeded: true)
        }

        _ = try await client.perform(.setPrivacy(
            deviceID: "DEVICE",
            action: .grant,
            service: .camera,
            bundleIdentifier: "com.example.app"
        ))

        #expect(endpoint.inboundMessages().contains { message in
            guard case let .setPrivatePrivacy(_, deviceID, action, service, bundleIdentifier) = message else {
                return false
            }
            return deviceID == "DEVICE" && action == .grant
                && service == .camera && bundleIdentifier == "com.example.app"
        })
        await client.stop()
    }

    @Test("Permission readback correlates the matching worker response")
    func correlatesPermissionReadback() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.capabilities([.extendedPermissions]))
        endpoint.emit(.context(99))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            guard case let .requestPrivacy(requestID, deviceID, bundleIdentifier) = message else {
                return nil
            }
            return .privacy(
                requestID: requestID,
                SimulatorPrivacySnapshot(
                    deviceID: deviceID,
                    bundleIdentifier: bundleIdentifier,
                    authorizations: [.camera: .granted, .notifications: .critical]
                )
            )
        }

        let result = try await client.perform(.readPrivacy(
            deviceID: "DEVICE",
            bundleIdentifier: "com.example.app"
        ))

        guard case let .privacy(snapshot) = result else {
            Issue.record("Expected a privacy snapshot")
            return
        }
        #expect(snapshot.authorizations[.camera] == .granted)
        #expect(snapshot.authorizations[.notifications] == .critical)
        await client.stop()
    }

    @Test("A worker that ignores SIGTERM is force-killed after the bounded grace")
    func escalatesTermination() async throws {
        let sleeper = ImmediateTerminationSleeper()
        let connection = try SimulatorProcessWorkerLauncher(
            terminationGrace: .seconds(30),
            sleeper: sleeper
        ).launch(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "trap '' TERM; printf '\\000\\000\\000\\001R'; while :; do read line || :; done",
            ],
            environment: [:]
        )
        var readiness = connection.messages.makeAsyncIterator()
        #expect(await readiness.next() == Data("R".utf8))

        connection.terminate()

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in connection.messages {}
                return true
            }
            group.addTask {
                try? await ContinuousClock().sleep(for: .seconds(3))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished)
        #expect(await sleeper.callCount == 1)
    }

    @Test("Discarding a worker cancels its pending graceful-exit deadline")
    func discardCancelsGracefulTerminationDeadline() async throws {
        let launcher = TestWorkerLauncher()
        let sleeper = CancellableWorkerSleeper()
        let client = makeClient(launcher: launcher, sleeper: sleeper)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))

        try await client.shutdownDevice(id: "DEVICE")
        for _ in 0..<100 {
            if await sleeper.hasStarted { break }
            await Task.yield()
        }
        #expect(endpoint.terminationCountValue() == 0)

        await client.invalidateWorker()
        for _ in 0..<100 {
            if await sleeper.wasCancelled { break }
            await Task.yield()
        }
        #expect(await sleeper.wasCancelled)
        #expect(endpoint.terminationCountValue() == 1)
        await client.stop()
    }

    @Test("Unrelated generic failures do not poison concurrent correlated requests")
    func isolatesConcurrentCorrelations() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.emit(.capabilities([.extendedPermissions, .cameraInjection]))
        endpoint.emit(.context(91))
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            endpoint.emit(.failure(SimulatorFailure(
                code: "unrelated_pointer_failure",
                message: "unrelated",
                isRecoverable: true
            )))
            switch message {
            case let .requestPrivacy(requestID, deviceID, bundleIdentifier):
                return .privacy(
                    requestID: requestID,
                    SimulatorPrivacySnapshot(
                        deviceID: deviceID,
                        bundleIdentifier: bundleIdentifier,
                        authorizations: [.camera: .granted]
                    )
                )
            case let .requestCameraStatus(requestID):
                return .cameraStatus(
                    requestID: requestID,
                    SimulatorCameraStatus(
                        configuration: .disabled,
                        mirrorMode: .auto,
                        injectedBundleIdentifiers: [],
                        hostCameras: []
                    )
                )
            default:
                return nil
            }
        }

        async let privacy = client.perform(.readPrivacy(
            deviceID: "DEVICE",
            bundleIdentifier: "com.example.app"
        ))
        async let camera = client.perform(.readCameraStatus)
        let (privacyResult, cameraResult) = try await (privacy, camera)

        guard case .privacy = privacyResult else {
            Issue.record("Expected correlated privacy result")
            return
        }
        guard case .cameraStatus = cameraResult else {
            Issue.record("Expected correlated camera status")
            return
        }
        await client.stop()
    }

    func makeClient(
        launcher: TestWorkerLauncher,
        control: any SimulatorControlling = TestSimulatorControl(),
        sleeper: any SimulatorWorkerSleeping = ContinuousSimulatorWorkerSleeper(),
        replayTimeout: Duration = .seconds(120)
    ) -> SimulatorWorkerClient {
        SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/fake/cmux"),
            arguments: [SimulatorWorkerClient.workerModeArgument],
            environment: [:],
            ackTimeout: .seconds(60),
            replayTimeout: replayTimeout,
            simulatorControl: control,
            launcher: launcher,
            sleeper: sleeper
        )
    }
}
