import Foundation
@testable import CmuxSimulator

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
