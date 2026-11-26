import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Restart replays the authoritative display orientation after attachment")
    func replaysDisplayOrientationAfterCrash() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        let display = SimulatorDisplayMetadata(
            width: 1_290,
            height: 2_796,
            orientation: .landscapeRight,
            scale: 3
        )
        first.emit(.display(display))
        #expect(await iterator.next() == .message(.display(display)))

        first.finish()
        #expect(await iterator.next() == .workerStopped)
        let second = try #require(await launcher.waitForEndpoint(at: 1))
        second.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        second.emit(.status(.streaming))
        let replay = await replayMessages(from: second) { messages in
            messages.contains(.attach(udid: "DEVICE", geometry: nil))
                && messages.contains(.rotate(.landscapeRight))
        }
        let attachIndex = try #require(replay.firstIndex(of: .attach(
            udid: "DEVICE",
            geometry: nil
        )))
        let orientationIndex = try #require(replay.firstIndex(of: .rotate(.landscapeRight)))

        #expect(attachIndex < orientationIndex)
        second.emit(.status(.streaming))
        await client.stop()
    }

    @Test("Restart releases every usage that a partially delivered text sequence could hold")
    func releasesPendingTextUsagesAfterCrash() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let sequence = try SimulatorUSKeyboardTextEncoder().encode("A?")
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        first.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        first.emit(.status(.streaming))
        #expect(await iterator.next() == .message(.status(.streaming)))
        let typing = Task {
            await client.send(.typeText(requestID: UUID(), sequence: sequence))
        }
        _ = try #require(await first.waitForInboundMessages { messages in
            messages.contains(where: {
                if case .typeText = $0 { true } else { false }
            })
        })

        first.finish()
        #expect(await iterator.next() == .workerStopped)
        await typing.value
        let second = try #require(await launcher.waitForEndpoint(at: 1))
        second.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        second.emit(.status(.streaming))
        let expectedUsages = Set(sequence.events.map(\.usage))
        let replay = await replayMessages(from: second) { messages in
            let released = Set(messages.compactMap { message -> UInt32? in
                guard case let .key(event) = message, event.phase == .up else { return nil }
                return event.usage
            })
            return released.isSuperset(of: expectedUsages)
        }
        let released = Set(replay.compactMap { message -> UInt32? in
            guard case let .key(event) = message, event.phase == .up else { return nil }
            return event.usage
        })
        #expect(released.isSuperset(of: expectedUsages))
        await client.stop()
    }

    @Test("Restart releases held input before replaying camera state and accepting new input")
    func replaysSessionStateAfterCrash() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        first.emit(.status(.streaming))
        first.emit(.capabilities([.cameraInjection]))
        first.emit(.frameTransport(simulatorFrameTransportDescriptor(42)))
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
                    succeeded: configuration == .placeholder,
                    targetBundleIdentifier: nil
                )
            case let .setCameraMirror(requestID, mode):
                return .cameraMirror(requestID: requestID, succeeded: mode == .on)
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(first)
        _ = try await client.perform(.configureCamera(.placeholder))
        _ = try await client.perform(.setCameraMirror(.on))
        let touch = SimulatorPointerEvent(
            phase: .began,
            primary: SimulatorPoint(x: 20, y: 30),
            secondary: nil,
            edge: .none
        )
        await client.send(.pointer(touch))
        await client.send(.key(SimulatorKeyEvent(usage: 4, phase: .down)))
        let heldButton = SimulatorHIDButtonUsage(page: 0x0C, usage: 0x30)
        await client.send(.hidButton(SimulatorHIDButtonEvent(
            button: heldButton,
            phase: .down
        )))
        _ = try #require(await first.waitForInboundMessages { messages in
            messages.contains(.hidButton(.init(
                button: heldButton,
                phase: .down
            )))
        })
        #expect(first.inboundMessages().contains(.hidButton(.init(
            button: heldButton,
            phase: .down
        ))))
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()

        first.finish()
        #expect(await iterator.next() == .workerStopped)
        let second = try #require(await launcher.waitForEndpoint(at: 1))
        second.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: configuration.targetBundleIdentifier
                )
            case let .setCameraMirror(requestID, _):
                return .cameraMirror(requestID: requestID, succeeded: true)
            default:
                return nil
            }
        }
        second.emit(.status(.streaming))
        let replay = await replayMessages(from: second) { messages in
            messages.contains { if case .attach = $0 { true } else { false } }
                && messages.contains { if case .configureCamera = $0 { true } else { false } }
                && messages.contains { if case .setCameraMirror = $0 { true } else { false } }
        }
        let attachIndex = try #require(replay.firstIndex { if case .attach = $0 { true } else { false } })
        let cancelledIndex = try #require(replay.firstIndex { message in
            guard case let .pointer(event) = message else { return false }
            return event.phase == .cancelled && event.primary == touch.primary
        })
        let keyUpIndex = try #require(replay.firstIndex { message in
            guard case let .key(event) = message else { return false }
            return event.usage == 4 && event.phase == .up
        })
        let buttonUpIndex = try #require(replay.firstIndex { message in
            guard case let .hidButton(event) = message else { return false }
            return event.button == heldButton && event.phase == .up
        })
        let cameraIndex = try #require(replay.firstIndex { message in
            guard case let .configureCamera(_, configuration) = message else { return false }
            return configuration == .placeholder
        })
        let mirrorIndex = try #require(replay.firstIndex { message in
            guard case let .setCameraMirror(_, mode) = message else { return false }
            return mode == .on
        })
        #expect(attachIndex < cancelledIndex)
        #expect(cancelledIndex < cameraIndex)
        #expect(keyUpIndex < cameraIndex)
        #expect(buttonUpIndex < cameraIndex)
        #expect(cameraIndex < mirrorIndex)

        let newTouch = SimulatorPointerEvent(
            phase: .began,
            primary: SimulatorPoint(x: 40, y: 50),
            secondary: nil,
            edge: .none
        )
        await client.send(.pointer(newTouch))
        #expect(second.inboundMessages().last(where: { message in
            guard case let .pointer(event) = message else { return false }
            return event.primary == newTouch.primary
        }) == .pointer(newTouch))
        await client.stop()
    }

    @Test("Restart restores every resolved camera target")
    func replaysMultipleCameraTargetsAfterCrash() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        first.emit(.status(.streaming))
        first.emit(.capabilities([.cameraInjection]))
        first.emit(.frameTransport(simulatorFrameTransportDescriptor(44)))
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        first.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, configuration):
                let target = configuration.targetBundleIdentifier ?? "com.example.inferred"
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: target
                )
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(first)

        _ = try await client.perform(.configureCamera(.placeholder))
        _ = try await client.perform(.configureCamera(.targeted(
            bundleIdentifier: "com.example.explicit",
            source: .placeholder
        )))
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()
        first.finish()
        #expect(await iterator.next() == .workerStopped)

        let second = try #require(await launcher.waitForEndpoint(at: 1))
        second.setResponder { message in
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
        second.emit(.status(.streaming))
        let replay = await replayMessages(from: second) { messages in
            messages.compactMap { message -> String? in
                guard case let .configureCamera(_, configuration) = message else { return nil }
                return configuration.targetBundleIdentifier
            }.count == 2
        }
        let targets = Set(replay.compactMap { message -> String? in
            guard case let .configureCamera(_, configuration) = message else { return nil }
            return configuration.targetBundleIdentifier
        })
        #expect(targets == ["com.example.inferred", "com.example.explicit"])
        await client.stop()
    }

    @Test("Source switch rewrites every replay target and preserves mirror mode")
    func sourceSwitchReplayState() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        endpoint.emit(.frameTransport(simulatorFrameTransportDescriptor(45)))
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
            case let .switchCameraSource(requestID, _):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: nil
                )
            case let .setCameraMirror(requestID, _):
                return .cameraMirror(requestID: requestID, succeeded: true)
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(endpoint)
        for target in ["com.example.a", "com.example.b"] {
            _ = try await client.perform(.configureCamera(.targeted(
                bundleIdentifier: target,
                source: .placeholder
            )))
        }
        _ = try await client.perform(.setCameraMirror(.on))
        _ = try await client.perform(.switchCameraSource(.hostCamera(deviceID: "HOST")))

        let replayConfigurations = await client.cameraReplayConfigurations
        #expect(replayConfigurations.count == 2)
        #expect(Set(replayConfigurations.compactMap(\.targetBundleIdentifier))
            == ["com.example.a", "com.example.b"])
        #expect(replayConfigurations.allSatisfy { configuration in
            guard case let .targeted(_, source) = configuration else { return false }
            return source == .hostCamera(deviceID: "HOST")
        })
        #expect(await client.lastCameraMirrorMode == .on)
        await client.stop()
    }

    @Test("A stalled automatic camera replay spends the restart fuse on its long deadline")
    func timesOutCameraReplay() async throws {
        let launcher = TestWorkerLauncher()
        let sleeper = CameraReplayDeadlineSleeper()
        let client = makeClient(
            launcher: launcher,
            sleeper: sleeper,
            replayTimeout: .milliseconds(1)
        )
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let readiness = await client.subscribe()
        var readinessIterator = readiness.makeAsyncIterator()
        first.emit(.status(.streaming))
        first.emit(.capabilities([.cameraInjection]))
        first.emit(.frameTransport(simulatorFrameTransportDescriptor(43)))
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        _ = await readinessIterator.next()
        first.setResponder { message in
            switch message {
            case let .ping(sequence):
                return .ack(sequence)
            case let .configureCamera(requestID, .placeholder):
                return .cameraConfiguration(
                    requestID: requestID,
                    succeeded: true,
                    targetBundleIdentifier: "com.example.camera"
                )
            default:
                return nil
            }
        }
        acknowledgeRecordedPings(first)
        _ = try await client.perform(.configureCamera(.placeholder))
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        _ = await iterator.next()
        _ = await iterator.next()

        first.finish()
        #expect(await iterator.next() == .workerStopped)
        let replacement = try #require(await launcher.waitForEndpoint(at: 1))
        replacement.emit(.status(.streaming))
        var timeoutEvent = await iterator.next()
        while timeoutEvent != .workerStopped {
            timeoutEvent = await iterator.next()
        }
        #expect(timeoutEvent == .workerStopped)
        guard case let .message(.failure(failure)) = await iterator.next() else {
            Issue.record("Expected replay timeout to trip the restart fuse")
            return
        }
        #expect(failure.code == "worker_crash_fuse")
        let replay = replacement.inboundMessages()
        #expect(replay.contains { message in
            guard case let .configureCamera(_, configuration) = message else { return false }
            return configuration == .targeted(
                bundleIdentifier: "com.example.camera",
                source: .placeholder
            )
        })
        await client.stop()
    }

    private func replayMessages(
        from endpoint: TestWorkerEndpoint,
        until complete: @escaping @Sendable ([SimulatorWorkerInbound]) -> Bool
    ) async -> [SimulatorWorkerInbound] {
        await endpoint.waitForInboundMessages(until: complete) ?? endpoint.inboundMessages()
    }

    private func acknowledgeRecordedPings(_ endpoint: TestWorkerEndpoint) {
        for sequence in endpoint.inboundMessages().compactMap({ message -> UInt64? in
            guard case let .ping(sequence) = message else { return nil }
            return sequence
        }) {
            endpoint.emit(.ack(sequence))
        }
    }

}
