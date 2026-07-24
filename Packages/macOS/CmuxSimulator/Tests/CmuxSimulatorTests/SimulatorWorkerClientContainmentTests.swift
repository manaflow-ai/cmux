import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Correlated timeouts terminate each generation, restart once, then trip the fuse")
    func correlatedTimeoutRecoveryAndFuse() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher, sleeper: ReplayDeadlineSleeper())
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()

        for expectedGeneration in 0..<2 {
            do {
                let _: Bool = try await client.requestWorkerValue(
                    sending: .requestCameraStatus(requestID: UUID()),
                    timeout: .milliseconds(1)
                ) { _ in nil }
                Issue.record("Expected correlated timeout")
            } catch let error as SimulatorControlError {
                #expect(error.code == "worker_response_timed_out")
            }
            let endpoint = try #require(launcher.endpoint(at: expectedGeneration))
            #expect(endpoint.terminationCountValue() == 1)
        }

        #expect(await client.crashFuseTripped)
        #expect(launcher.endpoint(at: 2) == nil)
        guard case let .message(.failure(failure)) = await iterator.next() else {
            Issue.record("Expected the timeout failure to be surfaced")
            return
        }
        #expect(failure.code == "worker_response_timed_out")
        await client.stop()
    }

    @Test("A replacement attach invalidates delayed events from the old generation")
    func replacementAttachFiltersStaleGeneration() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let firstTask = Task { try await client.activateDevice(id: "A", geometry: nil) }
        let first = try await endpoint(from: launcher, at: 0, containingAttach: "A")
        let firstGeneration = await client.generation

        let completion = AttachmentCompletionProbe()
        let secondTask = Task {
            try await client.activateDevice(id: "B", geometry: nil)
            await completion.markComplete()
        }
        let second = try await endpoint(from: launcher, at: 1, containingAttach: "B")
        #expect(first.terminationCountValue() == 1)

        await client.receive(
            try JSONEncoder().encode(SimulatorWorkerOutbound.frameTransport(
                simulatorFrameTransportDescriptor(111)
            )),
            generation: firstGeneration
        )
        await client.receive(
            try JSONEncoder().encode(SimulatorWorkerOutbound.status(.streaming)),
            generation: firstGeneration
        )
        await Task.yield()
        #expect(!(await completion.isComplete))
        #expect(await client.currentFrameTransport == nil)

        let secondTransport = simulatorFrameTransportDescriptor(222)
        second.emit(.frameTransport(secondTransport))
        second.emit(.status(.streaming))
        try await secondTask.value
        #expect(await completion.isComplete)
        #expect(await client.currentFrameTransport == secondTransport)
        #expect((await firstTask.result).isFailure)
        await client.stop()
    }

    @Test("A slow event subscriber invalidates the worker instead of dropping ordered events")
    func subscriberOverflowInvalidatesWorker() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        let subscription = await client.subscribe()
        await client.send(.releaseInputs)
        let first = try #require(launcher.endpoint(at: 0))

        for index in 0...SimulatorWorkerClient.maximumSubscriberEventCount {
            await client.broadcast(.message(.actionLog(SimulatorActionLogEntry(
                id: UUID(),
                timestamp: Date(),
                action: "flood",
                summary: String(index),
                succeeded: true
            ))))
        }

        #expect(first.terminationCountValue() == 1)
        let restarted = try #require(launcher.endpoint(at: 1))
        #expect(await client.restartAttemptUsed)

        restarted.emit(.status(.streaming))
        for _ in 0..<1_000 {
            if await client.currentStatus == .streaming { break }
            await Task.yield()
        }
        let recoverySubscription = await client.subscribe()
        var recoveryIterator = recoverySubscription.makeAsyncIterator()
        guard let replayedEvent = await recoveryIterator.next(),
              case .message(.status(.streaming)) = replayedEvent else {
            Issue.record("A replacement subscriber did not receive cached worker status")
            return
        }
        withExtendedLifetime(subscription) {}
        await client.stop()
    }

    @Test("Subscriber buffering admits inspector bursts up to a hard byte ceiling")
    func subscriberBufferUsesBytes() async {
        let source = SimulatorWorkerEventStreamSource(
            maximumBufferedBytes: 32 * 1_024 * 1_024,
            maximumBufferedEvents: 1_024,
            onTermination: {}
        )
        let stream = source.stream
        let continuation = source.continuation
        let event = SimulatorWorkerEvent.message(.actionLog(SimulatorActionLogEntry(
            id: UUID(),
            timestamp: Date(),
            action: "inspector",
            summary: "chunk",
            succeeded: true
        )))

        for _ in 0..<100 {
            #expect(await continuation.yield(event, byteCount: 300 * 1_024) == .enqueued)
        }
        for _ in 100..<109 {
            #expect(await continuation.yield(event, byteCount: 300 * 1_024) == .enqueued)
        }
        #expect(await continuation.yield(event, byteCount: 300 * 1_024) == .overflow)

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == event)
        #expect(await continuation.yield(event, byteCount: 300 * 1_024) == .enqueued)
        await continuation.finish()
    }

    @Test("Stop permanently prevents worker relaunch")
    func stopIsTerminal() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.releaseInputs)
        #expect(launcher.endpoint(at: 0) != nil)

        await client.stop()
        await client.send(.releaseInputs)

        #expect(await client.isPermanentlyStopped)
        #expect(await client.isClosing)
        #expect(launcher.endpoint(at: 1) == nil)
        do {
            try await client.recover()
            Issue.record("Expected terminal worker client failure")
        } catch let error as SimulatorControlError {
            #expect(error.code == "worker_permanently_stopped")
        }
        await #expect(throws: SimulatorControlError.self) {
            try await client.discoverDevices()
        }
        let stoppedStream = await client.subscribe()
        var stoppedIterator = stoppedStream.makeAsyncIterator()
        #expect(await stoppedIterator.next() == nil)
        #expect(await client.subscribers.isEmpty)
    }

    @Test("Dropping a client with a live reader terminates its worker")
    func droppedClientTerminatesLiveWorker() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-client-drop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        var client: SimulatorWorkerClient? = SimulatorWorkerClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > '\(marker.path)'; trap '' TERM; while :; do :; done",
            ],
            environment: [:],
            ackTimeout: .seconds(60),
            simulatorControl: TestSimulatorControl(),
            launcher: SimulatorProcessWorkerLauncher(
                terminationGrace: .seconds(30),
                sleeper: ImmediateTerminationSleeper()
            ),
            sleeper: ContinuousSimulatorWorkerSleeper()
        )
        weak let weakClient = client
        await client?.send(.releaseInputs)
        for _ in 0..<10_000 where !FileManager.default.fileExists(atPath: marker.path) {
            await Task.yield()
        }
        let processIdentifier = try #require(Int32(
            String(contentsOf: marker, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))

        client = nil
        for _ in 0..<10_000 where weakClient != nil { await Task.yield() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while Darwin.kill(processIdentifier, 0) == 0, clock.now < deadline {
            try await clock.sleep(for: .milliseconds(10))
        }
        #expect(weakClient == nil)
        #expect(Darwin.kill(processIdentifier, 0) != 0)
    }

    @Test("Crash between convenience-button phases replays a conservative up")
    func convenienceButtonCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let pingResponder = LimitedPingResponder(maximumAcknowledgements: 1)
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            default: pingResponder.response(to: message)
            }
        }
        let client = makeClient(launcher: launcher)
        try await client.activateDevice(id: "DEVICE", geometry: nil)
        let first = try #require(launcher.endpoint(at: 0))

        await client.send(.button(.volumeUp))
        for _ in 0..<1_000 {
            if first.inboundMessages().contains(.button(.volumeUp)) { break }
            await Task.yield()
        }
        #expect(first.inboundMessages().contains(.button(.volumeUp)))
        first.finish()

        var replacementCandidate: TestWorkerEndpoint?
        let expectedRelease = SimulatorWorkerInbound.hidButton(SimulatorHIDButtonEvent(
            button: SimulatorHIDButtonUsage(page: 0x0C, usage: 0xE9),
            phase: .up
        ))
        for _ in 0..<1_000 {
            replacementCandidate = launcher.endpoint(at: 1)
            if replacementCandidate?.inboundMessages().contains(expectedRelease) == true { break }
            await Task.yield()
        }
        let replacement = try #require(replacementCandidate)
        replacement.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        replacement.acknowledgeRecordedPings()
        replacement.emit(.status(.streaming))
        var inbound: [SimulatorWorkerInbound] = []
        for _ in 0..<10_000 {
            inbound = replacement.inboundMessages()
            if inbound.contains(expectedRelease) { break }
            await Task.yield()
        }
        #expect(inbound.contains(expectedRelease))
        await client.stop()
    }

    @Test("Queued raw input releases remain conservative until a ping proves them")
    func rawReleaseCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let pingResponder = LimitedPingResponder(maximumAcknowledgements: .max)
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            default: pingResponder.response(to: message)
            }
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let point = SimulatorPoint(x: 0.4, y: 0.5)
        let button = SimulatorHIDButtonUsage(page: 0x0C, usage: 0xE9)
        await client.send(.pointer(.init(phase: .began, primary: point)))
        await waitForAcknowledgedPing(client)
        await client.send(.key(.init(usage: 4, phase: .down)))
        await waitForAcknowledgedPing(client)
        await client.send(.hidButton(.init(button: button, phase: .down)))
        await waitForAcknowledgedPing(client)
        pingResponder.stopAcknowledging()
        await client.send(.pointer(.init(phase: .ended, primary: point)))
        await client.send(.key(.init(usage: 4, phase: .up)))
        await client.send(.hidButton(.init(button: button, phase: .up)))
        await client.send(.releaseInputs)

        first.finish()
        let second = try await replacementEndpoint(launcher)
        second.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        second.acknowledgeRecordedPings()
        second.emit(.status(.streaming))
        let expected = [
            SimulatorWorkerInbound.pointer(.init(phase: .cancelled, primary: point)),
            .key(.init(usage: 4, phase: .up)),
            .hidButton(.init(button: button, phase: .up)),
        ]
        var messages: [SimulatorWorkerInbound] = []
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            messages = second.inboundMessages()
            if expected.allSatisfy(messages.contains) { break }
            try await clock.sleep(for: .milliseconds(1))
        }
        let missingMessages = expected.filter { !messages.contains($0) }
        #expect(missingMessages.isEmpty)
        await client.stop()
    }

    @Test("Crash after a queued key-up ping but before its ack replays the up")
    func unacknowledgedReleaseCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        let pingResponder = LimitedPingResponder(maximumAcknowledgements: 2)
        launcher.setResponder { message in
            if case .attach = message { return .status(.streaming) }
            return pingResponder.response(to: message)
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        await waitForAcknowledgedPing(client)

        await client.send(.key(.init(usage: 4, phase: .down)))
        await waitForAcknowledgedPing(client)
        await client.send(.key(.init(usage: 4, phase: .up)))
        #expect(first.inboundMessages().filter { message in
            if case .ping = message { return true }
            return false
        }.count == 3)
        #expect(await client.pendingPingSequence != nil)

        first.finish()
        let second = try await replacementEndpoint(launcher)
        second.emit(.status(.streaming))
        for _ in 0..<1_000 {
            if second.inboundMessages().contains(.key(.init(usage: 4, phase: .up))) { break }
            await Task.yield()
        }
        #expect(second.inboundMessages().contains(.key(.init(usage: 4, phase: .up))))
        await client.stop()
    }

    @Test("Crash during correlated gesture replays a cancellation")
    func interactiveGestureCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            case let .ping(sequence): .ack(sequence)
            default: nil
            }
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let point = SimulatorPoint(x: 0.3, y: 0.7)
        let task = Task {
            try await client.perform(.interactive(.gesture([
                .init(phase: .began, primary: point),
                .init(phase: .ended, primary: point),
            ])))
        }
        try await awaitInboundInteractive(first)
        first.finish()
        _ = await task.result

        let second = try await replacementEndpoint(launcher)
        second.emit(.status(.streaming))
        for _ in 0..<1_000 {
            if second.inboundMessages().contains(
                .pointer(.init(phase: .cancelled, primary: point))
            ) { break }
            await Task.yield()
        }
        #expect(second.inboundMessages().contains(
            .pointer(.init(phase: .cancelled, primary: point))
        ))
        await client.stop()
    }

    @Test("Process worker drops ambient credentials and keeps required launch values")
    func processWorkerEnvironmentIsAllowlisted() {
        let environment = SimulatorProcessWorkerLauncher.workerEnvironment(
            inherited: [
                "HOME": "/Users/test",
                "PATH": "/usr/bin",
                "GITHUB_TOKEN": "secret",
                "CMUX_SOCKET_TOKEN": "secret",
            ],
            additional: ["CMUX_SIMULATOR_PROTOCOL": "1"]
        )

        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["CMUX_SIMULATOR_PROTOCOL"] == "1")
        #expect(environment["GITHUB_TOKEN"] == nil)
        #expect(environment["CMUX_SOCKET_TOKEN"] == nil)
    }

    private func replacementEndpoint(_ launcher: TestWorkerLauncher) async throws -> TestWorkerEndpoint {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let endpoint = launcher.endpoint(at: 1) { return endpoint }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw SimulatorControlError(
            code: "missing_replacement",
            arguments: [],
            message: "The replacement test worker did not launch."
        )
    }

    private func awaitInboundInteractive(_ endpoint: TestWorkerEndpoint) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if endpoint.inboundMessages().contains(where: {
                if case .interactiveAction = $0 { true } else { false }
            }) { return }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw SimulatorControlError(
            code: "missing_interactive",
            arguments: [],
            message: "The interactive test action was not sent."
        )
    }

    private func waitForAcknowledgedPing(_ client: SimulatorWorkerClient) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await client.currentStatus == .streaming,
               await client.pendingPingSequence == nil,
               await client.deferredMessages.isEmpty { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
    }

    private func endpoint(
        from launcher: TestWorkerLauncher,
        at index: Int,
        containingAttach deviceIdentifier: String
    ) async throws -> TestWorkerEndpoint {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let endpoint = launcher.endpoint(at: index),
               endpoint.inboundMessages().contains(.attach(
                   udid: deviceIdentifier,
                   geometry: nil
               )) {
                return endpoint
            }
            try await clock.sleep(for: .milliseconds(1))
        }
        throw SimulatorControlError(
            code: "missing_test_endpoint",
            arguments: [],
            message: "The expected test worker did not launch."
        )
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}
