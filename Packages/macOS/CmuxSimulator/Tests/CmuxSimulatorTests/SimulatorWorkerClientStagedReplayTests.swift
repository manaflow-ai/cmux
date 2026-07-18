import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("Automatic recovery stages attachment and camera work one response at a time")
    func stagesAutomaticReplay() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
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
            case let .setCameraMirror(requestID, _):
                return .cameraMirror(requestID: requestID, succeeded: true)
            default:
                return nil
            }
        }
        first.emit(.status(.streaming))
        first.emit(.capabilities([.cameraInjection]))
        for _ in 0..<1_000 {
            if await client.currentCapabilities.contains(.cameraInjection) { break }
            await Task.yield()
        }
        for index in 0..<9 {
            _ = try await client.perform(.configureCamera(.targeted(
                bundleIdentifier: "com.example.\(index)",
                source: .placeholder
            )))
        }
        _ = try await client.perform(.setCameraMirror(.on))

        first.finish()
        let replacement = try await replayReplacementEndpoint(launcher)
        let attachmentMessages = try #require(await replacement.waitForInboundMessages { messages in
            messages.contains(.attach(
                udid: "DEVICE",
                geometry: nil
            ))
        })
        #expect(attachmentMessages == [.attach(udid: "DEVICE", geometry: nil)])
        replacement.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        replacement.emit(.status(.streaming))

        for expectedCount in 1...9 {
            let messages = try #require(await replacement.waitForInboundMessages { messages in
                messages.compactMap { message -> UUID? in
                    guard case let .configureCamera(requestID, _) = message else { return nil }
                    return requestID
                }.count == expectedCount
            })
            let configurations = messages.compactMap { message -> (UUID, SimulatorCameraConfiguration)? in
                    guard case let .configureCamera(requestID, configuration) = message else {
                        return nil
                    }
                    return (requestID, configuration)
            }
            #expect(configurations.count == expectedCount)
            #expect(!messages.contains {
                if case .setCameraMirror = $0 { true } else { false }
            })
            let latest = try #require(configurations.last)
            replacement.emit(.cameraConfiguration(
                requestID: latest.0,
                succeeded: true,
                targetBundleIdentifier: latest.1.targetBundleIdentifier
            ))
        }
        let completedMessages = try #require(await replacement.waitForInboundMessages { messages in
            messages.contains(where: {
                if case .setCameraMirror = $0 { true } else { false }
            })
        })
        #expect(completedMessages.filter {
            if case .setCameraMirror = $0 { true } else { false }
        }.count == 1)
        await client.stop()
    }

    @Test("A camera result reconciles replay state after its caller is cancelled")
    func cancelledCameraWaiterStillReconcilesState() async throws {
        let launcher = TestWorkerLauncher()
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let endpoint = try #require(launcher.endpoint(at: 0))
        endpoint.setResponder { message in
            guard case let .ping(sequence) = message else { return nil }
            return .ack(sequence)
        }
        endpoint.emit(.status(.streaming))
        endpoint.emit(.capabilities([.cameraInjection]))
        for _ in 0..<1_000 {
            if await client.currentCapabilities.contains(.cameraInjection) { break }
            await Task.yield()
        }
        let configuration = SimulatorCameraConfiguration.placeholder
        let request = Task {
            try await client.perform(.configureCamera(configuration))
        }
        var requestIdentifier: UUID?
        for _ in 0..<1_000 {
            requestIdentifier = endpoint.inboundMessages().compactMap { message -> UUID? in
                guard case let .configureCamera(requestID, _) = message else { return nil }
                return requestID
            }.last
            if requestIdentifier != nil { break }
            await Task.yield()
        }
        let requestID = try #require(requestIdentifier)
        request.cancel()
        _ = await request.result
        endpoint.emit(.cameraConfiguration(
            requestID: requestID,
            succeeded: true,
            targetBundleIdentifier: "com.example.camera"
        ))
        for _ in 0..<1_000 {
            if await client.cameraReplayConfigurations.first?.targetBundleIdentifier
                == "com.example.camera" { break }
            await Task.yield()
        }
        #expect(await client.cameraReplayConfigurations == [.targeted(
            bundleIdentifier: "com.example.camera",
            source: .placeholder
        )])
        await client.stop()
    }

    private func replayReplacementEndpoint(
        _ launcher: TestWorkerLauncher
    ) async throws -> TestWorkerEndpoint {
        if let endpoint = await launcher.waitForEndpoint(at: 1) { return endpoint }
        throw SimulatorControlError(
            code: "missing_replacement",
            arguments: [],
            message: "The replacement test worker did not launch."
        )
    }
}
