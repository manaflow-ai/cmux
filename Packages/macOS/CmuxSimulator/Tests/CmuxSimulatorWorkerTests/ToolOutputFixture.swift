import Darwin
import Foundation
import Testing
import CmuxSimulator

final class ToolOutputFixture: @unchecked Sendable {
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

    func receiveAsync() async throws -> SimulatorWorkerOutbound {
        try await Task.detached {
            let data = try #require(self.host.receiveMessage())
            return try JSONDecoder().decode(SimulatorWorkerOutbound.self, from: data)
        }.value
    }

    func receiveAvailable() throws -> [SimulatorWorkerOutbound] {
        let originalFlags = fcntl(descriptors[0], F_GETFL)
        guard originalFlags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(descriptors[0], F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = fcntl(descriptors[0], F_SETFL, originalFlags) }

        var messages: [SimulatorWorkerOutbound] = []
        while let data = host.receiveMessage() {
            messages.append(try JSONDecoder().decode(SimulatorWorkerOutbound.self, from: data))
        }
        return messages
    }
}
