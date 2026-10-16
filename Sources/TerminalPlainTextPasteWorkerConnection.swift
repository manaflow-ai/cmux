import Darwin
import Foundation

/// Owns one isolated reader and its bounded request/response pipe protocol.
actor TerminalPlainTextPasteWorkerConnection {
    private enum Phase {
        case idle
        case reading(UUID)
        case closed
    }

    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let termination: AsyncStream<Int32>
    private var phase: Phase = .idle
    private var needsReadiness = true

    init(executableURL: URL) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--cmux-plain-text-paste-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let events = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
        termination = events.stream
        process.terminationHandler = { process in
            events.continuation.yield(process.terminationStatus)
            events.continuation.finish()
        }
        self.process = process
        // A crashed reader must report EPIPE instead of terminating the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func start() throws {
        do {
            try process.run()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        } catch {
            phase = .closed
            closePipes()
            throw error
        }
    }

    func request(_ data: Data) async throws -> (status: Int32, payload: Data) {
        guard case .idle = phase, data.count < 4095 else {
            throw TerminalPastePreparationWorkerError.invalidWorkerResponse
        }
        let id = UUID()
        phase = .reading(id)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let descriptor = output.fileHandleForReading.fileDescriptor
                if needsReadiness {
                    let ready = try await Self.readExactly(1, from: descriptor)
                    guard ready == Data([UInt8(ascii: "R")]) else {
                        throw TerminalPastePreparationWorkerError.invalidWorkerResponse
                    }
                    needsReadiness = false
                }
                try Task.checkCancellation()
                var message = data
                message.append(0x0a)
                try input.fileHandleForWriting.write(contentsOf: message)
                let header = try await Self.readExactly(5, from: descriptor)
                let status = Int32(header[0])
                let count = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                guard (status == 0 || status == 73), count <= 16 * 1024 * 1024,
                      status == 0 || count == 0 else {
                    throw TerminalPastePreparationWorkerError.invalidWorkerResponse
                }
                let payload = try await Self.readExactly(count, from: descriptor)
                try Task.checkCancellation()
                phase = .idle
                return (status, payload)
            } catch {
                await closeAndReap()
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { await self.cancel(requestID: id) }
        }
    }

    /// Blocking pipe reads run off the actor so cancellation can kill the peer.
    private nonisolated static func readExactly(
        _ count: Int,
        from descriptor: Int32
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            var result = Data(count: count)
            try result.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < count {
                    let received = Darwin.read(
                        descriptor,
                        bytes.baseAddress!.advanced(by: offset),
                        count - offset
                    )
                    if received < 0 && errno == EINTR { continue }
                    guard received > 0 else {
                        throw TerminalPastePreparationWorkerError.invalidWorkerResponse
                    }
                    offset += received
                }
            }
            return result
        }.value
    }

    private func cancel(requestID: UUID) {
        guard case .reading(let activeID) = phase,
              activeID == requestID, process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func closeAndReap() async {
        if case .closed = phase { return }
        phase = .closed
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        // The blocking read has returned before its descriptor is closed.
        // Retain the clipboard lease until Foundation has reaped the child.
        var exits = termination.makeAsyncIterator()
        _ = await exits.next()
        closePipes()
    }

    private func closePipes() {
        try? input.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    deinit {
        // EOF ends an idle server. Active requests retain this owner through
        // cancellation/reaping, so a provider cannot outlive an abandoned read.
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}
