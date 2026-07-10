import Darwin
import Foundation
import Testing
@testable import CmuxSimulator
@testable import CmuxSimulatorWorker

@Suite("Simulator accessibility request scheduling")
struct SimulatorAccessibilityRequestSchedulingTests {
    @Test("A blocked foreground read does not delay worker input acknowledgments")
    @MainActor
    func foregroundReadDoesNotBlockPing() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        let requestIdentifier = UUID()

        #expect(await coordinator.handle(.requestForegroundApplication(requestIdentifier)))
        await executor.waitForForegroundReadCount(1)
        #expect(await coordinator.handle(.ping(42)))
        #expect(try fixture.receive() == .ack(42))

        await executor.releaseForegroundRead()
        #expect(try await fixture.receiveAsync() == .foregroundApplication(
            requestID: requestIdentifier,
            GatedAccessibilityExecutor.application
        ))
    }

    @Test("Foreground reads coalesce behind one bounded private query")
    @MainActor
    func foregroundReadsAreBoundedAndCoalesced() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        let requestIdentifiers = (0...SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount)
            .map { _ in UUID() }

        for requestIdentifier in requestIdentifiers {
            #expect(await coordinator.handle(.requestForegroundApplication(requestIdentifier)))
        }

        guard case let .requestFailure(requestID, failure) = try fixture.receive() else {
            Issue.record("Expected the ninth foreground request to fail immediately")
            return
        }
        #expect(requestID == requestIdentifiers.last)
        #expect(failure.code == "foreground_request_busy")
        await executor.waitForForegroundReadCount(1)
        #expect(await executor.foregroundReadCount == 1)

        await executor.releaseForegroundRead()
        var completedIdentifiers: Set<UUID> = []
        for _ in 0..<SimulatorLengthPrefixedMessageChannel.maximumBufferedFrameCount {
            guard case let .foregroundApplication(requestID, application) =
                try await fixture.receiveAsync()
            else {
                Issue.record("Expected a coalesced foreground response")
                return
            }
            completedIdentifiers.insert(requestID)
            #expect(application == GatedAccessibilityExecutor.application)
        }
        #expect(completedIdentifiers == Set(requestIdentifiers.dropLast()))
        #expect(await executor.foregroundReadCount == 1)
    }

    @Test("A foreground result from a detached device is discarded")
    @MainActor
    func staleForegroundResultIsDiscarded() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "OLD"

        #expect(await coordinator.handle(.requestForegroundApplication(UUID())))
        await executor.waitForForegroundReadCount(1)
        coordinator.currentDeviceIdentifier = "NEW"
        await executor.releaseForegroundRead()
        while coordinator.foregroundApplicationTask != nil {
            await Task.yield()
        }

        #expect(await coordinator.handle(.ping(7)))
        #expect(try fixture.receive() == .ack(7))
    }

    @Test("A blocked accessibility snapshot releases the ordered worker consumer")
    @MainActor
    func accessibilitySnapshotDoesNotBlockConsumer() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        coordinator.currentDeviceIdentifier = "DEVICE"
        coordinator.currentDisplay = Self.display
        let completion = WorkerHandleCompletion()
        let requestIdentifier = UUID()

        let requestTask = Task { @MainActor in
            let result = await coordinator.handle(.requestAccessibility(requestIdentifier))
            await completion.finish(result)
        }
        await executor.waitForAccessibilityReadCount(1)
        for _ in 0..<200 where await completion.result == nil {
            await Task.yield()
        }
        #expect(await completion.result == true)

        #expect(await coordinator.handle(.ping(99)))
        #expect(try fixture.receive() == .ack(99))
        await executor.releaseAccessibilityRead()
        await requestTask.value
        #expect(try await fixture.receiveAsync() == .accessibility(
            requestID: requestIdentifier,
            GatedAccessibilityExecutor.snapshot
        ))
    }

    @Test("Camera setup releases the ordered worker consumer")
    @MainActor
    func cameraSetupDoesNotBlockConsumer() async throws {
        let executor = GatedAccessibilityExecutor()
        let fixture = try WorkerOutputFixture()
        let coordinator = SimulatorWorkerCoordinator(
            channel: fixture.worker,
            accessibilityExecutor: executor
        )
        let completion = WorkerHandleCompletion()

        let requestTask = Task { @MainActor in
            let result = await coordinator.handle(.configureCamera(
                requestID: UUID(),
                configuration: .placeholder
            ))
            await completion.finish(result)
        }
        await executor.waitForForegroundReadCount(1)
        for _ in 0..<200 where await completion.result == nil {
            await Task.yield()
        }
        #expect(await completion.result == true)

        #expect(await coordinator.handle(.ping(100)))
        #expect(try fixture.receive() == .ack(100))
        await executor.releaseForegroundRead()
        await requestTask.value
        await coordinator.shutdown()
    }

    fileprivate static let display = SimulatorDisplayMetadata(
        width: 1_200,
        height: 2_400,
        orientation: .portrait,
        scale: 3
    )
}

private actor GatedAccessibilityExecutor: SimulatorAccessibilityExecuting {
    static let application = SimulatorApplicationInfo(
        bundleIdentifier: "com.example.fixture",
        processIdentifier: 123,
        name: "Fixture",
        version: nil,
        build: nil,
        minimumOSVersion: nil,
        isReactNative: false
    )

    private var foregroundContinuation: CheckedContinuation<Void, Never>?
    private var foregroundReadObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var foregroundReadCount = 0
    private var accessibilityContinuation: CheckedContinuation<Void, Never>?
    private var accessibilityReadObservers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var accessibilityReadCount = 0

    static let snapshot = SimulatorAccessibilitySnapshot(
        roots: [],
        display: SimulatorAccessibilityRequestSchedulingTests.display,
        nodeCount: 0
    )

    func attach(device _: SimulatorAccessibilityDevice) -> Bool { true }

    func detach() {}

    func foregroundApplication() async throws -> SimulatorApplicationInfo? {
        foregroundReadCount += 1
        let observers = foregroundReadObservers
        foregroundReadObservers.removeAll()
        for (count, observer) in observers where foregroundReadCount >= count {
            observer.resume()
        }
        await withCheckedContinuation { foregroundContinuation = $0 }
        return Self.application
    }

    func accessibilitySnapshot(
        display: SimulatorDisplayMetadata
    ) async throws -> SimulatorAccessibilitySnapshot {
        accessibilityReadCount += 1
        let observers = accessibilityReadObservers
        accessibilityReadObservers.removeAll()
        for (count, observer) in observers where accessibilityReadCount >= count {
            observer.resume()
        }
        await withCheckedContinuation { accessibilityContinuation = $0 }
        return SimulatorAccessibilitySnapshot(
            roots: Self.snapshot.roots,
            display: display,
            nodeCount: Self.snapshot.nodeCount
        )
    }

    func waitForForegroundReadCount(_ count: Int) async {
        guard foregroundReadCount < count else { return }
        await withCheckedContinuation { foregroundReadObservers.append((count, $0)) }
    }

    func releaseForegroundRead() {
        foregroundContinuation?.resume()
        foregroundContinuation = nil
    }

    func waitForAccessibilityReadCount(_ count: Int) async {
        guard accessibilityReadCount < count else { return }
        await withCheckedContinuation { accessibilityReadObservers.append((count, $0)) }
    }

    func releaseAccessibilityRead() {
        accessibilityContinuation?.resume()
        accessibilityContinuation = nil
    }
}

private actor WorkerHandleCompletion {
    private(set) var result: Bool?

    func finish(_ result: Bool) {
        self.result = result
    }
}

private final class WorkerOutputFixture: @unchecked Sendable {
    private let descriptors: [Int32]
    let worker: SimulatorLengthPrefixedMessageChannel
    private let host: SimulatorLengthPrefixedMessageChannel

    init() throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptors = descriptors
        worker = SimulatorLengthPrefixedMessageChannel(readFD: -1, writeFD: descriptors[1])
        host = SimulatorLengthPrefixedMessageChannel(readFD: descriptors[0], writeFD: -1)
    }

    deinit {
        descriptors.forEach { close($0) }
    }

    func receive() throws -> SimulatorWorkerOutbound {
        let data = try #require(host.receiveMessage())
        return try JSONDecoder().decode(SimulatorWorkerOutbound.self, from: data)
    }

    func receiveAsync() async throws -> SimulatorWorkerOutbound {
        try await Task.detached { try self.receive() }.value
    }
}
