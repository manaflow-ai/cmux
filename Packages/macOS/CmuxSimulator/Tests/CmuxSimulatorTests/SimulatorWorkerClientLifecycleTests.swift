import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Correlated replies bypass lifecycle fanout")
    func correlatedRepliesRouteDirectly() async throws {
        let client = makeClient(launcher: TestWorkerLauncher())
        let lifecycle = await client.subscribe()
        var lifecycleIterator = lifecycle.makeAsyncIterator()
        let requestID = UUID()
        let request = try await client.registerRequestSubscriber(requestID)
        var requestIterator = request.makeAsyncIterator()
        let status = SimulatorCameraStatus(
            configuration: .disabled,
            mirrorMode: .auto,
            injectedBundleIdentifiers: [],
            hostCameras: []
        )
        let action = SimulatorActionLogEntry(
            id: UUID(), timestamp: Date(), action: "tap", summary: "ok", succeeded: true
        )

        await client.broadcast(.message(.cameraStatus(requestID: requestID, status)))
        await client.broadcast(.message(.actionLog(action)))

        #expect(await requestIterator.next() == .message(.cameraStatus(requestID: requestID, status)))
        #expect(await lifecycleIterator.next() == .message(.actionLog(action)))
        await client.removeRequestSubscriber(requestID)
        await client.stop()
    }

    @Test("A correlated camera handshake buffers target resolution and completion")
    func correlatedCameraHandshakeBuffersBothMessages() async throws {
        let client = makeClient(launcher: TestWorkerLauncher())
        let requestID = UUID()
        let request = try await client.registerRequestSubscriber(requestID)
        var iterator = request.makeAsyncIterator()
        let resolved = SimulatorWorkerEvent.message(.cameraTargetResolved(
            requestID: requestID,
            bundleIdentifier: "com.example.camera"
        ))
        let configured = SimulatorWorkerEvent.message(.cameraConfiguration(
            requestID: requestID,
            succeeded: true,
            targetBundleIdentifier: "com.example.camera"
        ))

        await client.broadcast(resolved)
        await client.broadcast(configured)

        #expect(await iterator.next() == resolved)
        #expect(await iterator.next() == configured)
        #expect(await client.requestSubscribers[requestID] != nil)
        await client.removeRequestSubscriber(requestID)
        await client.stop()
    }

    @Test("Text replies resolve both the request and pane completion streams")
    func textRepliesPreservePaneCompletion() async throws {
        let client = makeClient(launcher: TestWorkerLauncher())
        let lifecycle = await client.subscribe()
        var lifecycleIterator = lifecycle.makeAsyncIterator()
        let requestID = UUID()
        let request = try await client.registerRequestSubscriber(requestID)
        var requestIterator = request.makeAsyncIterator()
        let reply = SimulatorWorkerEvent.message(.textInput(
            requestID: requestID,
            succeeded: true
        ))

        await client.broadcast(reply)

        #expect(await requestIterator.next() == reply)
        #expect(await lifecycleIterator.next() == reply)
        await client.removeRequestSubscriber(requestID)
        await client.stop()
    }

    @Test("Correlated request routing has a hard waiter limit")
    func correlatedRequestCapacityIsBounded() async throws {
        let client = makeClient(launcher: TestWorkerLauncher())
        var streams: [SimulatorWorkerEventStream] = []
        for _ in 0..<SimulatorWorkerClient.maximumPendingRequestCount {
            streams.append(try await client.registerRequestSubscriber(UUID()))
        }

        await #expect(throws: SimulatorControlError.self) {
            _ = try await client.registerRequestSubscriber(UUID())
        }
        #expect(await client.requestSubscribers.count == SimulatorWorkerClient.maximumPendingRequestCount)
        withExtendedLifetime(streams) {}
        await client.stop()
    }

    @Test("Worker stop wakes and removes correlated request waiters")
    func workerStopWakesCorrelatedRequests() async throws {
        let client = makeClient(launcher: TestWorkerLauncher())
        let requestID = UUID()
        let operation = Task<SimulatorCameraStatus, Error> {
            try await client.requestWorkerValue(
                sending: .requestCameraStatus(requestID: requestID),
                timeout: .seconds(60),
                timeoutRecovery: .preserveWorker
            ) { message in
                guard case let .cameraStatus(responseID, status) = message,
                      responseID == requestID else { return nil }
                return status
            }
        }
        for _ in 0..<1_000 {
            if await client.requestSubscribers[requestID] != nil { break }
            await Task.yield()
        }
        #expect(await client.requestSubscribers[requestID] != nil)

        await client.broadcast(.workerStopped)

        do {
            _ = try await operation.value
            Issue.record("Expected worker stop to fail the pending request")
        } catch let error as SimulatorControlError {
            #expect(error.code == "worker_stopped")
        }
        #expect(await client.requestSubscribers.isEmpty)
        await client.stop()
    }

    @Test("Replacing a framebuffer transport retains both names until host adoption")
    func replacementFrameTransportRetainsNamesUntilAdoption() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let first = simulatorFrameTransportDescriptor(901)
        let second = simulatorFrameTransportDescriptor(902)

        endpoint.emit(.frameTransport(first))
        endpoint.emit(.frameTransport(second))
        for _ in 0..<1_000 {
            if await client.currentFrameTransport == second { break }
            await Task.yield()
        }

        #expect(await client.frameTransportSharedMemoryNames == [
            first.sharedMemoryName,
            second.sharedMemoryName,
        ])
        let inboundCountBeforeAdoption = endpoint.inboundMessages().count
        await client.acknowledgeFrameTransportAdoption(first)
        #expect(await client.frameTransportSharedMemoryNames == [
            first.sharedMemoryName,
            second.sharedMemoryName,
        ])
        await client.acknowledgeFrameTransportAdoption(second)
        #expect(await client.frameTransportSharedMemoryNames == [second.sharedMemoryName])
        #expect(endpoint.inboundMessages().count == inboundCountBeforeAdoption + 1)
        await client.stop()
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
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.extendedPermissions, .cameraInjection]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(91)))
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        endpoint.setResponder { message in
            endpoint.emit(.failure(SimulatorFailure(
                code: "unrelated_pointer_failure",
                message: "unrelated",
                isRecoverable: true
            )))
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
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
        endpoint.acknowledgeRecordedPings()

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
}
