import Darwin
@preconcurrency import Foundation

/// Drains Chromium diagnostics and publishes its loopback DevTools readiness.
///
/// Chromium emits one authoritative `DevTools listening on ...` line after its
/// CDP server is bound. Consuming that process signal avoids startup polling,
/// while continuing to drain the descriptor prevents child-process backpressure.
struct ChromiumProcessDiagnostics: Sendable {
    private static let readinessPrefix = "DevTools listening on "
    private static let maximumLineBytes = 64 * 1024

    private let readiness: AsyncStream<Result<Int, CDPError>>

    init(pipe: Pipe) throws {
        let descriptor = Darwin.dup(pipe.fileHandleForReading.fileDescriptor)
        guard descriptor >= 0 else {
            throw CDPError.disconnected(Self.posixErrorDescription(errno))
        }
        let pair = AsyncStream<Result<Int, CDPError>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        readiness = pair.stream
        Task.detached {
            Self.drain(descriptor: descriptor, readiness: pair.continuation)
        }
    }

    func waitForReadiness(expectedPort: Int) async throws {
        for await result in readiness {
            let actualPort = try result.get()
            guard actualPort == expectedPort else { throw CDPError.invalidEndpoint }
            return
        }
        throw CDPError.disconnected(ChromiumBrowserDiagnostic.endpointUnavailable.message)
    }

    static func port(from line: String) -> Int? {
        guard let prefixRange = line.range(of: readinessPrefix) else { return nil }
        let rawURL = line[prefixRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "ws",
              url.host?.lowercased() == ChromiumLaunchArguments.loopbackAddress,
              let port = url.port,
              ChromiumRemoteDebuggingPort(rawValue: port)?.isExternallyAttachable == true else {
            return nil
        }
        return port
    }

    /// The detached task performs only blocking POSIX reads against a raw,
    /// Sendable descriptor, as required for continuous Process pipe draining.
    private static func drain(
        descriptor: Int32,
        readiness: AsyncStream<Result<Int, CDPError>>.Continuation
    ) {
        defer { Darwin.close(descriptor) }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var publishedReadiness = false

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                pending.append(contentsOf: buffer.prefix(count))
                consumeLines(from: &pending) { line in
                    guard !publishedReadiness, let port = port(from: line) else { return }
                    publishedReadiness = true
                    readiness.yield(.success(port))
                    readiness.finish()
                }
                if pending.count > maximumLineBytes {
                    pending.removeFirst(pending.count - maximumLineBytes)
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if !publishedReadiness {
                let error: CDPError
                if count < 0 {
                    error = .disconnected(posixErrorDescription(errno))
                } else {
                    error = .disconnected(ChromiumBrowserDiagnostic.endpointUnavailable.message)
                }
                readiness.yield(.failure(error))
                readiness.finish()
            }
            return
        }
    }

    private static func consumeLines(
        from data: inout Data,
        consume: (String) -> Void
    ) {
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = Data(data[..<newline])
            data.removeSubrange(...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            consume(line)
        }
    }

    private static func posixErrorDescription(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
