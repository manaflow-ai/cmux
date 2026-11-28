package import CmuxNextCompat
package import CmuxNextWakeups
public import Foundation

/// Runs `/usr/bin/osascript` with arguments and returns its standard output: the seam that
/// ``MailAppVerificationSource`` reads Mail through, so tests pass a fake.
public protocol VerificationScriptRunning: Sendable {
    /// - Parameter arguments: The `osascript` arguments.
    /// - Returns: Standard output.
    /// - Throws: ``VerificationScriptFailure`` on a non-zero exit.
    func run(_ arguments: [String]) async throws -> String
}

/// `osascript` exited non-zero.
public nonisolated struct VerificationScriptFailure: Error, Sendable, Hashable {
    public let status: Int32
    /// Standard error, trimmed.
    public let message: String

    public init(status: Int32, message: String) {
        self.status = status
        self.message = message
    }
}

/// The real runner: one `osascript` process per call, its pipes drained concurrently.
public nonisolated struct OsascriptRunner: VerificationScriptRunning {
    public init() {}

    @concurrent public func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        let exited = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        try process.run()
        let outputFD = output.fileHandleForReading.fileDescriptor, errorFD = errors.fileHandleForReading.fileDescriptor
        async let out = Self.drain(outputFD)
        async let err = Self.drain(errorFD)
        let (stdout, stderr) = await (out, err)
        var status: Int32 = -1
        for await code in exited.stream { status = code }
        guard status == 0 else {
            throw VerificationScriptFailure(status: status, message: String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: stdout, as: UTF8.self)
    }

    /// Reads a pipe to its end, by raw descriptor (an `Int32` is `Sendable`), without holding a
    /// thread: FileHandle calls a readability handler when bytes are ready, and the handler takes
    /// them with one `read(2)`. End of file or a read error ends the drain with what arrived;
    /// FirstOutcome resumes the wait once even if the handler runs again after that.
    @concurrent private static func drain(_ fd: Int32) async -> Data {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let collected = PipeOutput()
        let outcome = FirstOutcome<Data>()
        handle.readabilityHandler = { handle in
            switch handle.readReady() {
            case .bytes(let data): collected.append(data)
            case .retry: return
            case .end:
                handle.readabilityHandler = nil
                outcome.resolve(collected.data)
            }
        }
        let data = await outcome.value()
        // The handle owns the readability source: keep it until the drain ends.
        withExtendedLifetime(handle) {}
        return data
    }
}

/// One pipe's output so far, appended by its readability handler.
private nonisolated final class PipeOutput: Sendable {
    private let storage = Mutex(Data())

    package func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    package var data: Data {
        storage.withLock { $0 }
    }
}
