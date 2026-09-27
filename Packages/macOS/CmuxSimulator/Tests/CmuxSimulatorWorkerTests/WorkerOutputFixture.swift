import CmuxSimulator
import Darwin
import Foundation
import Testing

final class WorkerOutputFixture: @unchecked Sendable {
    private let descriptors: [Int32]
    let worker: SimulatorLengthPrefixedMessageChannel
    private let host: SimulatorLengthPrefixedMessageChannel

    init(nonblockingWrites: Bool = false) throws {
        var descriptors = [Int32](repeating: 0, count: 2)
        guard pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptors = descriptors
        worker = SimulatorLengthPrefixedMessageChannel(
            readFD: -1,
            writeFD: descriptors[1],
            nonblockingWrites: nonblockingWrites
        )
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
