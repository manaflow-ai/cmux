import Darwin
import Foundation
@testable import CmuxSimulatorWorker

@MainActor
final class FailingWebInspectorTransport: SimulatorWebInspectorTransport {
    nonisolated let messages: AsyncStream<Data>
    private let failAtSend: Int
    private var sends = 0

    init(failAtSend: Int = 1) {
        self.failAtSend = failAtSend
        messages = AsyncStream { _ in }
    }

    var sendCount: Int { sends }

    func send(propertyList: [String: Any]) throws {
        sends += 1
        if sends >= failAtSend {
            throw SimulatorWebInspectorError.socketFailure(EPIPE)
        }
    }

    func close() {}
}
