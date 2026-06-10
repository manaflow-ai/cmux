import Foundation
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSocketControl
import CoreFoundation
import CryptoKit
import Darwin
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Sentry)
import Sentry
#endif


// MARK: - Socket client core
final class SocketClient {
    struct RelayEndpoint {
        let host: String
        let port: UInt16
    }

    struct SocketConnectError: Error, CustomStringConvertible {
        let path: String
        let errnoValue: Int32

        var description: String {
            "Failed to connect to socket at \(path) (\(String(cString: strerror(errnoValue))), errno \(errnoValue))"
        }
    }

    struct RelayCredentials {
        let relayID: String
        let relayToken: Data
    }

    let path: String
    var socketFD: Int32 = -1
    var lastConfiguredReceiveTimeout: TimeInterval?
    private var lastOperationTelemetry: CLISocketOperationTelemetry.State?
    private static let defaultResponseTimeoutSeconds: TimeInterval = 15.0
    static let multilineResponseIdleTimeoutSeconds: TimeInterval = 0.12
    private static let maxSocketTimeoutSeconds: TimeInterval = 9_007_199_254_740_991
    static let connectRetryDeadline: TimeInterval = 0.35
    static let connectRetryIntervalMicros: useconds_t = 25_000
    static let responseTimeoutSeconds: TimeInterval = {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"],
           let seconds = Double(raw),
           seconds.isFinite,
           seconds > 0 {
            return seconds
        }
        return defaultResponseTimeoutSeconds
    }()

    static func isCompleteSingleLineResponse(_ data: Data) -> Bool {
        guard data.contains(UInt8(0x0A)),
              let response = String(data: data, encoding: .utf8) else {
            return false
        }
        let normalized = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !normalized.contains("\n") else {
            return false
        }

        if normalized == "OK" ||
            normalized == "PONG" ||
            normalized.hasPrefix("OK ") ||
            normalized.hasPrefix("ERROR:") {
            return true
        }

        if let jsonData = normalized.data(using: .utf8), (try? JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])) != nil {
            return true
        }

        return false
    }

    init(path: String) {
        self.path = path
    }

    var socketPath: String {
        path
    }

    var isRelayBacked: Bool {
        relayEndpoint != nil
    }

    func connectionAppearsOpen() -> Bool {
        if relayEndpoint != nil, socketFD < 0 {
            do {
                try connect()
            } catch {
                return false
            }
        }
        guard socketFD >= 0 else { return false }
        while true {
            var descriptor = pollfd(
                fd: socketFD,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let ready = Darwin.poll(&descriptor, 1, 0)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            let terminalEvents = Int16(POLLHUP | POLLERR | POLLNVAL)
            return descriptor.revents & terminalEvents == 0
        }
    }

    func operationTelemetryContext() -> [String: Any] {
        lastOperationTelemetry?.context() ?? [:]
    }

    func hasUnfinishedOperationTelemetry() -> Bool { lastOperationTelemetry.map { $0.phase != .completed } ?? false }

    var relayEndpoint: RelayEndpoint? {
        Self.parseRelayEndpoint(path)
    }

    static func trimmedEnvValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    static func socketTimeval(for timeout: TimeInterval) -> timeval {
        let sanitizedTimeout = timeout.isFinite ? timeout : defaultResponseTimeoutSeconds
        let clampedTimeout = min(max(sanitizedTimeout, 0.01), maxSocketTimeoutSeconds)
        let seconds = floor(clampedTimeout)
        let microseconds = min(
            max(Int((clampedTimeout - seconds) * 1_000_000), 0),
            999_999
        )
        return timeval(
            tv_sec: Int(seconds),
            tv_usec: __darwin_suseconds_t(microseconds)
        )
    }

    func recordOperation(_ operation: CLISocketOperationTelemetry.State) {
        lastOperationTelemetry = operation
    }

}

