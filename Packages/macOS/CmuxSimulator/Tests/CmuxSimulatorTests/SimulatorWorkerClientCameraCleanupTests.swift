import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
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
        first.emit(.context(77))
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
        var replayMessages: [SimulatorWorkerInbound] = []
        for _ in 0..<1_000 {
            replayMessages = second.inboundMessages().filter {
                if case .configureCamera = $0 { return true }
                return false
            }
            if replayMessages.count == 2 { break }
            await Task.yield()
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

        let expectedActions = cameraCleanupActions(
            deviceIdentifier: deviceIdentifier,
            bundleIdentifiers: ["com.example.a", "com.example.b"]
        )
        #expect(await control.actions == expectedActions)
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
        for _ in 0..<1_000 {
            if third.inboundMessages().contains(where: {
                guard case .configureCamera = $0 else { return false }
                return true
            }) { break }
            await Task.yield()
        }
        let replayTargets = Set(third.inboundMessages().compactMap { message -> String? in
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
        endpoint.emit(.context(78))
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
        #expect(await control.actions == cameraCleanupActions(
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
        for _ in 0..<1_000 {
            if let endpoint = launcher.endpoint(at: index) { return endpoint }
            await Task.yield()
        }
        throw SimulatorControlError(
            code: "missing_test_worker",
            arguments: [],
            message: "The expected test worker did not launch."
        )
    }

    private func cameraCleanupActions(
        deviceIdentifier: String,
        bundleIdentifiers: [String]
    ) -> [SimulatorControlAction] {
        bundleIdentifiers.sorted().flatMap { bundleIdentifier in
            [
                .terminateApplication(
                    deviceID: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier
                ),
                .launchApplication(
                    deviceID: deviceIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    configuration: SimulatorLaunchConfiguration(
                        terminateRunningProcess: true
                    )
                ),
            ]
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

private actor BlockingCameraCleanupControl: SimulatorControlling {
    private(set) var actions: [SimulatorControlAction] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isBlocked = false

    func discoverDevices() async throws -> [SimulatorDevice] { [] }
    func boot(deviceID: String) async throws {}
    func waitUntilBooted(deviceID: String) async throws {}
    func shutdown(deviceID: String) async throws {}

    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        if !released, !isBlocked, case .terminateApplication = action {
            isBlocked = true
            await withCheckedContinuation { continuation = $0 }
        }
        return .none
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class TestCameraSharedMemoryRegion {
    private let name: String
    private let descriptor: Int32

    init(deviceIdentifier: String, processIdentifier: Int32) throws {
        name = SimulatorCameraSharedMemory.name(
            deviceIdentifier: deviceIdentifier,
            processIdentifier: processIdentifier
        )
        _ = Darwin.shm_unlink(name)
        descriptor = try Self.open(name: name, flags: O_CREAT | O_EXCL | O_RDWR)
        guard ftruncate(descriptor, 1) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            _ = Darwin.shm_unlink(name)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    deinit {
        Darwin.close(descriptor)
        _ = Darwin.shm_unlink(name)
    }

    func exists() -> Bool {
        guard let descriptor = try? Self.open(name: name, flags: O_RDWR) else { return false }
        Darwin.close(descriptor)
        return true
    }

    private static func open(name: String, flags: Int32) throws -> Int32 {
        typealias Function = @convention(c) (
            UnsafePointer<CChar>,
            Int32,
            mode_t
        ) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "shm_open") else {
            throw POSIXError(.ENOSYS)
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        let descriptor = name.withCString {
            function($0, flags, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}
