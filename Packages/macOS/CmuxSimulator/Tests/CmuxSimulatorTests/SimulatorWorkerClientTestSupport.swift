import Foundation
@testable import CmuxSimulator

actor ImmediateTerminationSleeper: SimulatorWorkerSleeping {
    private(set) var callCount = 0

    func sleep(for duration: Duration) async throws {
        callCount += 1
    }
}

actor CancellableWorkerSleeper: SimulatorWorkerSleeping {
    private var started = false
    private var cancelled = false

    var hasStarted: Bool { started }
    var wasCancelled: Bool { cancelled }

    func sleep(for duration: Duration) async throws {
        started = true
        do {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        } catch {
            cancelled = true
            throw error
        }
    }
}

final class TestWorkerLauncher: SimulatorWorkerLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let processIdentifiers: [Int32?]
    private var endpoints: [TestWorkerEndpoint] = []
    private var responder: (@Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?)?

    init(processIdentifiers: [Int32?] = []) {
        self.processIdentifiers = processIdentifiers
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> SimulatorWorkerConnection {
        lock.lock()
        let endpointIndex = endpoints.count
        let processIdentifier = processIdentifiers.indices.contains(endpointIndex)
            ? processIdentifiers[endpointIndex]
            : nil
        let endpoint = TestWorkerEndpoint(processIdentifier: processIdentifier)
        let responder = self.responder
        endpoints.append(endpoint)
        lock.unlock()
        if let responder { endpoint.setResponder(responder) }
        return endpoint.connection
    }

    func setResponder(
        _ responder: @escaping @Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?
    ) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    func endpoint(at index: Int) -> TestWorkerEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        guard endpoints.indices.contains(index) else { return nil }
        return endpoints[index]
    }
}

struct ReplayDeadlineSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {
        if duration == .milliseconds(1) { return }
        try await ContinuousClock().sleep(for: .seconds(3_600))
    }
}

actor CameraReplayDeadlineSleeper: SimulatorWorkerSleeping {
    private var replayCallCount = 0

    func sleep(for duration: Duration) async throws {
        guard duration == .milliseconds(1) else {
            try await ContinuousClock().sleep(for: .seconds(3_600))
            return
        }
        replayCallCount += 1
        if replayCallCount == 1 {
            try await ContinuousClock().sleep(for: .seconds(3_600))
        }
    }
}

final class TestWorkerEndpoint: @unchecked Sendable {
    let processIdentifier: Int32?
    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private let stream: AsyncStream<Data>
    private var sentData: [Data] = []
    private var responder: (@Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?)?
    private var nextSendFailure: (@Sendable (SimulatorWorkerInbound) -> Bool)?

    init(processIdentifier: Int32? = nil) {
        self.processIdentifier = processIdentifier
        let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
        self.stream = stream
        self.continuation = continuation
    }

    var connection: SimulatorWorkerConnection {
        SimulatorWorkerConnection(
            processIdentifier: processIdentifier,
            messages: stream,
            send: { [weak self] data in try self?.append(data) },
            closeInput: { [weak self] in self?.finish() },
            terminate: { [weak self] in self?.terminate() },
            terminalFailure: { nil }
        )
    }

    private(set) var terminationCount = 0

    func terminate() {
        lock.withLock { terminationCount += 1 }
        finish()
    }

    func terminationCountValue() -> Int {
        lock.withLock { terminationCount }
    }

    func finish() {
        continuation.finish()
    }

    func emit(_ message: SimulatorWorkerOutbound) {
        if let data = try? JSONEncoder().encode(message) {
            continuation.yield(data)
        }
    }

    func setResponder(
        _ responder: @escaping @Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?
    ) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    func inboundMessages() -> [SimulatorWorkerInbound] {
        lock.lock()
        let data = sentData
        lock.unlock()
        return data.compactMap { try? JSONDecoder().decode(SimulatorWorkerInbound.self, from: $0) }
    }

    func acknowledgeRecordedPings() {
        for sequence in inboundMessages().compactMap({ message -> UInt64? in
            guard case let .ping(sequence) = message else { return nil }
            return sequence
        }) {
            emit(.ack(sequence))
        }
    }

    func failNextSend(
        where predicate: @escaping @Sendable (SimulatorWorkerInbound) -> Bool
    ) {
        lock.withLock { nextSendFailure = predicate }
    }

    private func append(_ data: Data) throws {
        let message = try JSONDecoder().decode(SimulatorWorkerInbound.self, from: data)
        lock.lock()
        if let nextSendFailure, nextSendFailure(message) {
            self.nextSendFailure = nil
            lock.unlock()
            throw SimulatorChannelError.writeFailed
        }
        sentData.append(data)
        let responder = self.responder
        lock.unlock()
        guard let response = responder?(message),
              let responseData = try? JSONEncoder().encode(response) else { return }
        continuation.yield(responseData)
    }
}

actor TestSimulatorControl: SimulatorControlling {
    private let devices: [SimulatorDevice]
    private(set) var bootDeviceIDs: [String] = []
    private(set) var waitDeviceIDs: [String] = []
    private(set) var shutdownDeviceIDs: [String] = []
    private(set) var actions: [SimulatorControlAction] = []

    init(devices: [SimulatorDevice] = []) {
        self.devices = devices
    }

    func discoverDevices() async throws -> [SimulatorDevice] { devices }
    func boot(deviceID: String) async throws { bootDeviceIDs.append(deviceID) }
    func waitUntilBooted(deviceID: String) async throws { waitDeviceIDs.append(deviceID) }
    func shutdown(deviceID: String) async throws { shutdownDeviceIDs.append(deviceID) }
    func perform(_ action: SimulatorControlAction) async throws -> SimulatorControlResult {
        actions.append(action)
        return .none
    }
}
