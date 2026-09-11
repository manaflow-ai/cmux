import Darwin
import Foundation

/// Receives the exact reviewed bytes from the raw, no-echo sudo PTY.
struct SudoPrivilegedScriptReceiver {
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let temporaryDirectoryURL: URL
    private let markers: SudoExecutionControlMarkers

    init(
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        temporaryDirectoryURL: URL = URL(fileURLWithPath: "/var/root", isDirectory: true),
        markers: SudoExecutionControlMarkers = SudoExecutionControlMarkers()
    ) {
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.temporaryDirectoryURL = temporaryDirectoryURL
        self.markers = markers
    }

    func withReceivedDescriptor<Value>(
        expectedByteCount: Int,
        deadline: Date = .distantFuture,
        operation: (Int32) throws -> Value
    ) throws -> Value {
        guard (0...SudoResourcePolicy.standard.maximumScriptBytes)
            .contains(expectedByteCount) else {
            throw Failure.invalidByteCount
        }

        var originalTerminal = termios()
        guard tcgetattr(inputDescriptor, &originalTerminal) == 0 else {
            throw Failure.terminal(errno)
        }
        var rawTerminal = originalTerminal
        cfmakeraw(&rawTerminal)
        guard tcsetattr(inputDescriptor, TCSANOW, &rawTerminal) == 0 else {
            throw Failure.terminal(errno)
        }
        var terminalNeedsRestore = true
        defer {
            if terminalNeedsRestore {
                _ = tcsetattr(inputDescriptor, TCSANOW, &originalTerminal)
            }
        }

        try writeAll(markers.inputReady, to: outputDescriptor)
        let descriptor = try makeAnonymousDescriptor()
        defer { Darwin.close(descriptor) }
        try copyExactly(
            expectedByteCount,
            from: inputDescriptor,
            to: descriptor,
            deadline: deadline
        )
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw Failure.seek(errno)
        }
        guard tcsetattr(inputDescriptor, TCSANOW, &originalTerminal) == 0 else {
            throw Failure.terminal(errno)
        }
        terminalNeedsRestore = false
        return try operation(descriptor)
    }

    private func makeAnonymousDescriptor() throws -> Int32 {
        var template = Array(
            temporaryDirectoryURL
                .appendingPathComponent(".cmux-sudo-root.XXXXXX")
                .path
                .utf8CString
        )
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else { throw Failure.create(errno) }
        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard unlink(path) == 0 else {
            Darwin.close(descriptor)
            throw Failure.unlink(errno)
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            Darwin.close(descriptor)
            throw Failure.permissions(errno)
        }
        return descriptor
    }

    private func copyExactly(
        _ byteCount: Int,
        from source: Int32,
        to destination: Int32,
        deadline: Date
    ) throws {
        let originalFlags = fcntl(source, F_GETFL)
        guard originalFlags >= 0,
              fcntl(source, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw Failure.read(errno)
        }
        defer { _ = fcntl(source, F_SETFL, originalFlags) }

        var remaining = byteCount
        var buffer = [UInt8](repeating: 0, count: min(max(byteCount, 1), 64 * 1_024))
        while remaining > 0 {
            let remainingSeconds = deadline.timeIntervalSinceNow
            guard remainingSeconds > 0 else { throw Failure.timeout }
            var pollState = pollfd(
                fd: source,
                events: Int16(POLLIN),
                revents: 0
            )
            let timeoutMilliseconds = Int32(
                min(
                    Double(Int32.max),
                    max(1, (remainingSeconds * 1_000).rounded(.up))
                )
            )
            let pollResult = Darwin.poll(
                &pollState,
                1,
                timeoutMilliseconds
            )
            if pollResult < 0, errno == EINTR { continue }
            guard pollResult > 0 else {
                throw Failure.timeout
            }
            let requestedCount = min(remaining, buffer.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, requestedCount)
            }
            if count > 0 {
                try writeAll(Data(buffer.prefix(count)), to: destination)
                remaining -= count
            } else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw Failure.read(count == 0 ? EIO : errno)
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    data.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw Failure.write(count == 0 ? EIO : errno)
            }
        }
    }

    enum Failure: Error {
        case invalidByteCount
        case terminal(Int32)
        case create(Int32)
        case unlink(Int32)
        case permissions(Int32)
        case read(Int32)
        case timeout
        case write(Int32)
        case seek(Int32)
    }
}
