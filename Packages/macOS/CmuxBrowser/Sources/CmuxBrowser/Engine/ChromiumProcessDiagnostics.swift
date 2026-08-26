import Darwin
@preconcurrency import Foundation

/// Drains Chromium diagnostics and publishes its loopback DevTools readiness.
///
/// Chromium emits one authoritative `DevTools listening on ...` line after its
/// CDP server is bound. Consuming that process signal avoids startup polling,
/// while continuing to drain the descriptor prevents child-process backpressure.
struct ChromiumProcessDiagnostics: Sendable {
    // SAFETY: this flag is confined to the diagnostics read-source queue.
    private final class ReadinessState: @unchecked Sendable {
        var published = false
    }

    private static let readinessPrefix = "DevTools listening on "
    private static let maximumLineBytes = 64 * 1024

    private let readiness: AsyncStream<Result<Int, CDPError>>
    private let readSource: ChromiumPipeReadSource

    init(pipe: Pipe) throws {
        let descriptor = Darwin.dup(pipe.fileHandleForReading.fileDescriptor)
        guard descriptor >= 0 else {
            throw CDPError.disconnected(Self.posixErrorDescription(errno))
        }
        let pair = AsyncStream<Result<Int, CDPError>>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        readiness = pair.stream
        let readBuffer = ChromiumPipeReadBuffer(
            delimiter: 0x0A,
            maximumPendingBytes: Self.maximumLineBytes
        )
        let state = ReadinessState()
        do {
            readSource = try ChromiumPipeReadSource(
                descriptor: descriptor,
                label: "com.cmux.chromium.diagnostics-reader"
            ) {
                let shouldContinue = readBuffer.read(
                    from: descriptor,
                    onMessage: { lineData in
                        guard !state.published,
                              let line = String(data: lineData, encoding: .utf8),
                              let port = Self.port(from: line) else { return }
                        state.published = true
                        pair.continuation.yield(.success(port))
                        pair.continuation.finish()
                    },
                    onEnd: { _, errorCode in
                        guard !state.published else { return }
                        let error: CDPError
                        if let errorCode {
                            error = .disconnected(Self.posixErrorDescription(errorCode))
                        } else {
                            error = .disconnected(ChromiumBrowserDiagnostic.endpointUnavailable.message)
                        }
                        pair.continuation.yield(.failure(error))
                        pair.continuation.finish()
                    }
                )
                // Readiness is a one-shot publication, but the descriptor must
                // remain drained until Chromium exits so later diagnostics
                // cannot fill stderr and block the child process.
                return shouldContinue
            }
        } catch {
            throw error
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

    private static func posixErrorDescription(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
