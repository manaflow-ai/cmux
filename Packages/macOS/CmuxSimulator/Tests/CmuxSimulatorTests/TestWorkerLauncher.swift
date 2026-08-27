import Foundation
@testable import CmuxSimulator

final class TestWorkerLauncher: SimulatorWorkerLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let processIdentifiers: [Int32?]
    private let launchContinuation: AsyncStream<Void>.Continuation
    private let launchStream: AsyncStream<Void>
    private var endpoints: [TestWorkerEndpoint] = []
    private var responder: (@Sendable (SimulatorWorkerInbound) -> SimulatorWorkerOutbound?)?

    init(processIdentifiers: [Int32?] = []) {
        self.processIdentifiers = processIdentifiers
        let (launchStream, launchContinuation) = AsyncStream.makeStream(of: Void.self)
        self.launchStream = launchStream
        self.launchContinuation = launchContinuation
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
        launchContinuation.yield()
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

    func waitForEndpoint(at index: Int, timeout: Duration = .seconds(5)) async -> TestWorkerEndpoint? {
        if let endpoint = endpoint(at: index) { return endpoint }
        return await withTaskGroup(of: TestWorkerEndpoint?.self) { group in
            group.addTask { [launchStream] in
                for await _ in launchStream {
                    if let endpoint = self.endpoint(at: index) { return endpoint }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let endpoint = await group.next() ?? nil
            group.cancelAll()
            return endpoint
        }
    }
}
