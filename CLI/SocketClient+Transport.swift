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


// MARK: - Connect, send, relay transport
extension SocketClient {
    func connect() throws {
        if socketFD >= 0 { return }
        let deadline = Date().addingTimeInterval(Self.connectRetryDeadline)
        while true {
            do {
                try connectOnce()
                return
            } catch {
                guard Self.shouldRetryConnect(error), Date() < deadline else {
                    throw error
                }
                usleep(Self.connectRetryIntervalMicros)
            }
        }
    }

    func connectWithoutRetry(responseTimeout: TimeInterval? = nil) throws {
        if socketFD >= 0 { return }
        try connectOnce(responseTimeout: responseTimeout)
    }

    func close() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        lastConfiguredReceiveTimeout = nil
    }

    func send(command: String, responseTimeout: TimeInterval? = nil) throws -> String {
        if relayEndpoint != nil, socketFD < 0 {
            try connect()
        }
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let shouldCloseAfterSend = relayEndpoint != nil
        defer {
            if shouldCloseAfterSend {
                close()
            }
        }

        let initialResponseTimeout = responseTimeout ?? Self.responseTimeoutSeconds
        if lastConfiguredReceiveTimeout != initialResponseTimeout {
            try configureReceiveTimeout(initialResponseTimeout)
        }
        _ = try? configureSocketWriteSafety(initialResponseTimeout)
        var operation = CLISocketOperationTelemetry.State(
            name: CLISocketOperationTelemetry.operationName(for: command),
            timeout: initialResponseTimeout,
            startedAt: Date(),
            phase: .writeRequest
        )
        recordOperation(operation)

        let payload = command + "\n"
        try writeAll(
            Data(payload.utf8),
            timeoutMessage: "Command timed out",
            failureMessage: "Failed to write to socket"
        )

        var data = Data()
        var sawNewline = false
        var receivedCompleteResponse = false

        while true {
            let currentTimeout = sawNewline ? Self.multilineResponseIdleTimeoutSeconds : initialResponseTimeout
            operation.phase = sawNewline ? .readMultilineResponse : .waitForResponse
            operation.sawNewline = sawNewline
            operation.timeout = currentTimeout
            recordOperation(operation)
            if lastConfiguredReceiveTimeout != currentTimeout {
                try configureReceiveTimeout(currentTimeout)
            }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if sawNewline {
                        receivedCompleteResponse = true
                        break
                    }
                    throw CLIError(message: "Command timed out")
                }
                throw CLIError(message: "Socket read error")
            }
            if count == 0 {
                operation.sawNewline = sawNewline
                recordOperation(operation)
                if data.isEmpty {
                    throw CLIError(message: "Socket closed before reply")
                }
                if !sawNewline {
                    throw CLIError(message: "Socket closed before complete reply")
                }
                receivedCompleteResponse = true
                break
            }
            data.append(buffer, count: count)
            operation.bytesRead += count
            if data.contains(UInt8(0x0A)) {
                sawNewline = true
                if Self.isCompleteSingleLineResponse(data) {
                    receivedCompleteResponse = true
                    break
                }
            }
        }

        operation.sawNewline = sawNewline
        if receivedCompleteResponse {
            operation.phase = .completed
        }
        recordOperation(operation)

        guard var response = String(data: data, encoding: .utf8) else {
            throw CLIError(message: "Invalid UTF-8 response")
        }
        if response.hasSuffix("\n") {
            response.removeLast()
        }
        return response
    }

    func sendOneWay(command: String, writeTimeout: TimeInterval) throws {
        if relayEndpoint != nil, socketFD < 0 {
            try connect()
        }
        guard socketFD >= 0 else { throw CLIError(message: "Not connected") }
        let shouldCloseAfterSend = relayEndpoint != nil

        try configureSocketWriteSafety(writeTimeout)
        var operation = CLISocketOperationTelemetry.State(
            name: CLISocketOperationTelemetry.operationName(for: command),
            timeout: writeTimeout,
            startedAt: Date(),
            phase: .writeRequest
        )
        recordOperation(operation)

        do {
            try writeAllNonBlocking(
                Data((command + "\n").utf8),
                deadline: Date().addingTimeInterval(writeTimeout),
                timeoutMessage: "Command timed out",
                failureMessage: "Failed to write to socket"
            )
        } catch {
            close()
            throw error
        }
        operation.phase = .completed
        recordOperation(operation)
        if shouldCloseAfterSend {
            close()
        } else {
            if (try? configureSocketWriteSafety(Self.responseTimeoutSeconds)) == nil {
                close()
            }
        }
    }

    private func connectOnce(responseTimeout: TimeInterval? = nil) throws {
        if let relayEndpoint {
            try connectToRelay(endpoint: relayEndpoint, responseTimeout: responseTimeout)
            return
        }

        // Verify socket is owned by the current user to prevent fake-socket attacks.
        var st = stat()
        guard stat(path, &st) == 0 else {
            throw CLIError(message: "Socket not found at \(path)")
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            throw CLIError(message: "Path exists at \(path) but is not a Unix socket")
        }
        guard st.st_uid == getuid() else {
            throw CLIError(message: "Socket at \(path) is not owned by the current user — refusing to connect")
        }

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        if socketFD < 0 {
            throw CLIError(message: "Failed to create socket")
        }
        do {
            let timeout = responseTimeout ?? Self.responseTimeoutSeconds
            try configureSocketWriteSafety(timeout)
            try configureReceiveTimeout(timeout)
        } catch {
            close()
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return
        }

        let connectErrno = errno
        Darwin.close(socketFD)
        socketFD = -1
        throw SocketConnectError(path: path, errnoValue: connectErrno)
    }

    private static func shouldRetryConnect(_ error: Error) -> Bool {
        guard let error = error as? SocketConnectError else {
            return false
        }
        switch error.errnoValue {
        case ECONNREFUSED, EAGAIN, EWOULDBLOCK:
            return true
        default:
            return false
        }
    }

    static func parseRelayEndpoint(_ raw: String) -> RelayEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/") else {
            return nil
        }
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let port = UInt16(components[1]),
              port > 0 else {
            return nil
        }
        let host = String(components[0]).lowercased()
        guard host == "127.0.0.1" || host == "localhost" else {
            return nil
        }
        return RelayEndpoint(host: host == "localhost" ? "127.0.0.1" : host, port: port)
    }

    private static func relayCredentials(for endpoint: RelayEndpoint) throws -> RelayCredentials {
        let environment = ProcessInfo.processInfo.environment
        if let relayID = trimmedEnvValue(environment["CMUX_RELAY_ID"]),
           let relayTokenHex = trimmedEnvValue(environment["CMUX_RELAY_TOKEN"]),
           let relayToken = hexData(from: relayTokenHex) {
            return RelayCredentials(relayID: relayID, relayToken: relayToken)
        }

        let authURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cmux/relay/\(endpoint.port).auth", isDirectory: false)
        guard let authData = try? Data(contentsOf: authURL),
              let authObject = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let relayID = trimmedEnvValue(authObject["relay_id"] as? String),
              let relayTokenHex = trimmedEnvValue(authObject["relay_token"] as? String),
              let relayToken = hexData(from: relayTokenHex) else {
            throw CLIError(message: "Missing relay auth metadata for \(endpoint.host):\(endpoint.port)")
        }

        return RelayCredentials(relayID: relayID, relayToken: relayToken)
    }

    private static func hexData(from string: String) -> Data? {
        let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count.isMultiple(of: 2) else {
            return nil
        }

        var data = Data(capacity: normalized.count / 2)
        var cursor = normalized.startIndex
        while cursor < normalized.endIndex {
            let next = normalized.index(cursor, offsetBy: 2)
            guard let byte = UInt8(normalized[cursor..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            cursor = next
        }
        return data
    }

    private static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func connectToRelay(endpoint: RelayEndpoint, responseTimeout: TimeInterval? = nil) throws {
        let credentials = try Self.relayCredentials(for: endpoint)
        let timeout = responseTimeout ?? Self.responseTimeoutSeconds

        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw CLIError(message: "Failed to create relay socket")
        }
        do {
            try configureSocketWriteSafety(timeout)
            try configureReceiveTimeout(timeout)
        } catch {
            close()
            throw error
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = endpoint.port.bigEndian
        let parsedAddress = withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            endpoint.host.withCString { hostPointer in
                inet_pton(AF_INET, hostPointer, pointer)
            }
        }
        guard parsedAddress == 1 else {
            close()
            throw CLIError(message: "Invalid relay endpoint \(endpoint.host):\(endpoint.port)")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        if result != 0 {
            let connectErrno = errno
            close()
            throw CLIError(
                message: "Failed to connect to relay at \(endpoint.host):\(endpoint.port) (\(String(cString: strerror(connectErrno))), errno \(connectErrno))"
            )
        }

        do {
            try authenticateRelay(credentials: credentials, responseTimeout: timeout)
        } catch {
            close()
            throw error
        }
    }

    private func authenticateRelay(credentials: RelayCredentials, responseTimeout: TimeInterval) throws {
        let challengeLine = try readLine(responseTimeout: responseTimeout)
        guard let challengeData = challengeLine.data(using: .utf8),
              let challenge = try JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              (challenge["protocol"] as? String) == "cmux-relay-auth",
              let version = challenge["version"] as? Int,
              let relayID = challenge["relay_id"] as? String,
              relayID == credentials.relayID,
              let nonce = challenge["nonce"] as? String,
              !nonce.isEmpty else {
            throw CLIError(message: "Invalid relay authentication challenge")
        }

        let authMessage = Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        let key = SymmetricKey(data: credentials.relayToken)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: authMessage, using: key))
        let authPayload = try JSONSerialization.data(withJSONObject: [
            "relay_id": relayID,
            "mac": Self.hexString(from: mac),
        ])
        try writeAll(
            authPayload + Data([0x0A]),
            timeoutMessage: "Relay command timed out",
            failureMessage: "Failed to write to relay socket"
        )

        let authResponseLine = try readLine(responseTimeout: responseTimeout)
        guard let authResponseData = authResponseLine.data(using: .utf8),
              let authResponse = try JSONSerialization.jsonObject(with: authResponseData) as? [String: Any],
              (authResponse["ok"] as? Bool) == true else {
            throw CLIError(message: "Relay authentication failed")
        }
    }

}
