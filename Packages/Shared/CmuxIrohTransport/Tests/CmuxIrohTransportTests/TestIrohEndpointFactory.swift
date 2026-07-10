@testable import CmuxIrohTransport

actor TestIrohEndpointFactory: CmxIrohEndpointFactory {
    private var endpoints: [TestIrohEndpoint]
    private var configurations: [CmxIrohEndpointConfiguration] = []
    private let bindStream: AsyncStream<Int>
    private let bindContinuation: AsyncStream<Int>.Continuation

    init(endpoints: [TestIrohEndpoint]) {
        self.endpoints = endpoints
        let binds = AsyncStream<Int>.makeStream()
        bindStream = binds.stream
        bindContinuation = binds.continuation
    }

    func bind(
        configuration: CmxIrohEndpointConfiguration
    ) throws -> any CmxIrohEndpoint {
        guard !endpoints.isEmpty else {
            throw TestIrohTransportError.noEndpoint
        }
        configurations.append(configuration)
        bindContinuation.yield(configurations.count)
        return endpoints.removeFirst()
    }

    func bindEvents() -> AsyncStream<Int> {
        bindStream
    }

    func observedConfigurations() -> [CmxIrohEndpointConfiguration] {
        configurations
    }
}
