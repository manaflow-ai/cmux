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
        SimulatorAccessibilitySnapshot(roots: [], display: display, nodeCount: 0)
    }

    func waitForForegroundReadCount(_ count: Int) async {
        guard foregroundReadCount < count else { return }
        await withCheckedContinuation { foregroundReadObservers.append((count, $0)) }
    }

    func releaseForegroundRead() {
        foregroundContinuation?.resume()
        foregroundContinuation = nil
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
