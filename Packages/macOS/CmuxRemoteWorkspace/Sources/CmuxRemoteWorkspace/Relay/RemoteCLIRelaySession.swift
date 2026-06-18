import CryptoKit
import Darwin
import Foundation
import Network
import Security

extension RemoteCLIRelayServer {
    /// One authenticated relay connection: sends the HMAC challenge, awaits
    /// the MAC line, then forwards exactly one rewritten command line to the
    /// local cmux unix socket and returns the response (faithful lift of the
    /// legacy nested `WorkspaceRemoteCLIRelayServer.Session`).
    ///
    /// Isolation design: all mutable state is confined to the server's
    /// serial `queue` (Network callbacks hop onto it; the blocking unix
    /// round trip runs on a global utility queue and hops back).
    /// `@unchecked Sendable` because `@Sendable` Network/Task callbacks
    /// capture `self`; queue confinement is the safety argument.
    final class Session: @unchecked Sendable {
        private enum Phase {
            case awaitingAuth
            case awaitingCommand
            case forwarding
            case closed
        }

        private let connection: NWConnection
        private let localSocketPath: String
        private let relayID: String
        private let relayToken: Data
        private let commandRewriter: (Data) -> Data
        private let queue: DispatchQueue
        private let clock: any RemoteProxyRetryClock
        private let onClose: () -> Void
        private let challengeProtocol = "cmux-relay-auth"
        private let challengeVersion = 1
        private let minimumFailureDelay: TimeInterval = 0.05
        private let maximumFrameBytes = 16 * 1024

        private var buffer = Data()
        private var phase: Phase = .awaitingAuth
        private var challengeNonce = ""
        private var challengeSentAt = Date()
        private var isClosed = false

        init(
            connection: NWConnection,
            localSocketPath: String,
            relayID: String,
            relayToken: Data,
            commandRewriter: @escaping (Data) -> Data,
            queue: DispatchQueue,
            clock: any RemoteProxyRetryClock,
            onClose: @escaping () -> Void
        ) {
            self.connection = connection
            self.localSocketPath = localSocketPath
            self.relayID = relayID
            self.relayToken = relayToken
            self.commandRewriter = commandRewriter
            self.queue = queue
            self.clock = clock
            self.onClose = onClose
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    self.handleState(state)
                }
            }
            connection.start(queue: queue)
        }

        func stop() {
            close()
        }

        private func handleState(_ state: NWConnection.State) {
            guard !isClosed else { return }
            switch state {
            case .ready:
                sendChallenge()
                receive()
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }

        private func sendChallenge() {
            challengeSentAt = Date()
            challengeNonce = Self.randomHex(byteCount: 16)
            let challenge: [String: Any] = [
                "protocol": challengeProtocol,
                "version": challengeVersion,
                "relay_id": relayID,
                "nonce": challengeNonce,
            ]
            sendJSONLine(challenge) { _ in }
        }

        private func receive() {
            guard !isClosed else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumFrameBytes) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                self.queue.async {
                    if error != nil {
                        self.close()
                        return
                    }
                    if let data, !data.isEmpty {
                        self.buffer.append(data)
                        if self.buffer.count > self.maximumFrameBytes {
                            self.sendFailureAndClose()
                            return
                        }
                        self.processBufferedLines()
                    }
                    if isComplete {
                        self.close()
                        return
                    }
                    if !self.isClosed {
                        self.receive()
                    }
                }
            }
        }

        private func processBufferedLines() {
            while let newlineIndex = buffer.firstIndex(of: 0x0A), !isClosed {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)
                let line = String(data: lineData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                switch phase {
                case .awaitingAuth:
                    handleAuthLine(line)
                case .awaitingCommand:
                    handleCommandLine(Data(lineData) + Data([0x0A]))
                case .forwarding, .closed:
                    return
                }
            }
        }

        private func handleAuthLine(_ line: String) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let receivedRelayID = object["relay_id"] as? String,
                  receivedRelayID == relayID,
                  let macHex = object["mac"] as? String,
                  let receivedMAC = Self.hexData(from: macHex)
            else {
                sendFailureAndClose()
                return
            }

            let message = Self.authMessage(relayID: relayID, nonce: challengeNonce, version: challengeVersion)
            let expectedMAC = Self.authMAC(token: relayToken, message: message)
            guard Self.constantTimeEqual(receivedMAC, expectedMAC) else {
                sendFailureAndClose()
                return
            }

            phase = .awaitingCommand
            sendJSONLine(["ok": true]) { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.processBufferedLines()
                }
            }
        }

        private func handleCommandLine(_ commandLine: Data) {
            guard !commandLine.isEmpty else {
                sendFailureAndClose()
                return
            }
            phase = .forwarding
            let forwardedCommandLine = commandRewriter(commandLine)
            DispatchQueue.global(qos: .utility).async { [localSocketPath, forwardedCommandLine, queue] in
                let result = Result {
                    try Self.roundTripUnixSocket(socketPath: localSocketPath, request: forwardedCommandLine)
                }
                queue.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let response):
                        self.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                            guard let self else { return }
                            self.queue.async {
                                self.close()
                            }
                        })
                    case .failure:
                        self.sendFailureAndClose()
                    }
                }
            }
        }

        private func sendFailureAndClose() {
            let elapsed = Date().timeIntervalSince(challengeSentAt)
            let delay = max(0, minimumFailureDelay - elapsed)
            phase = .closed
            // Anti-timing-oracle minimum delay via the injected clock (legacy
            // used queue.asyncAfter); ceil keeps the floor a true minimum.
            let delayMilliseconds = Int((delay * 1000).rounded(.up))
            Task { [weak self, clock] in
                if delayMilliseconds > 0 {
                    guard (try? await clock.sleep(forMilliseconds: delayMilliseconds)) != nil else { return }
                }
                guard let self else { return }
                self.queue.async {
                    self.sendJSONLine(["ok": false]) { [weak self] _ in
                        guard let self else { return }
                        self.queue.async {
                            self.close()
                        }
                    }
                }
            }
        }

        private func sendJSONLine(_ object: [String: Any], completion: @escaping @Sendable (NWError?) -> Void) {
            guard !isClosed else {
                completion(nil)
                return
            }
            guard let payload = try? JSONSerialization.data(withJSONObject: object) else {
                completion(nil)
                return
            }
            connection.send(content: payload + Data([0x0A]), completion: .contentProcessed(completion))
        }

        private func close() {
            guard !isClosed else { return }
            isClosed = true
            phase = .closed
            connection.stateUpdateHandler = nil
            connection.cancel()
            onClose()
        }

        private static func authMessage(relayID: String, nonce: String, version: Int) -> Data {
            Data("relay_id=\(relayID)\nnonce=\(nonce)\nversion=\(version)".utf8)
        }

        static func authMAC(token: Data, message: Data) -> Data {
            let key = SymmetricKey(data: token)
            let code = HMAC<SHA256>.authenticationCode(for: message, using: key)
            return Data(code)
        }

        private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
            guard lhs.count == rhs.count else { return false }
            var diff: UInt8 = 0
            for index in lhs.indices {
                diff |= lhs[index] ^ rhs[index]
            }
            return diff == 0
        }

        static func hexData(from string: String) -> Data? {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count.isMultiple(of: 2), !normalized.isEmpty else { return nil }
            var data = Data(capacity: normalized.count / 2)
            var cursor = normalized.startIndex
            while cursor < normalized.endIndex {
                let next = normalized.index(cursor, offsetBy: 2)
                guard let byte = UInt8(normalized[cursor..<next], radix: 16) else { return nil }
                data.append(byte)
                cursor = next
            }
            return data
        }

        private static func randomHex(byteCount: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: byteCount)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        private static func roundTripUnixSocket(socketPath: String, request: Data) throws -> Data {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: "cmux.remote.relay", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "failed to create local relay socket",
                ])
            }
            defer { Darwin.close(fd) }

            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            withUnsafePointer(to: &timeout) { pointer in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw NSError(domain: "cmux.remote.relay", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "local relay socket path is too long",
                ])
            }
            let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            withUnsafeMutableBytes(of: &address) { rawBuffer in
                let destination = rawBuffer.baseAddress!.advanced(by: sunPathOffset)
                pathBytes.withUnsafeBytes { pathBuffer in
                    destination.copyMemory(from: pathBuffer.baseAddress!, byteCount: pathBytes.count)
                }
            }

            let addressLength = socklen_t(MemoryLayout.size(ofValue: address.sun_family) + pathBytes.count)
            let connectResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, addressLength)
                }
            }
            guard connectResult == 0 else {
                throw NSError(domain: "cmux.remote.relay", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "failed to connect to local cmux socket",
                ])
            }

            try request.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                var bytesRemaining = rawBuffer.count
                var pointer = baseAddress
                while bytesRemaining > 0 {
                    let written = Darwin.write(fd, pointer, bytesRemaining)
                    if written <= 0 {
                        throw NSError(domain: "cmux.remote.relay", code: 4, userInfo: [
                            NSLocalizedDescriptionKey: "failed to write relay request",
                        ])
                    }
                    bytesRemaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
            _ = shutdown(fd, SHUT_WR)

            var response = Data()
            var scratch = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(fd, &scratch, scratch.count)
                if count > 0 {
                    response.append(scratch, count: count)
                    continue
                }
                if count == 0 {
                    break
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if !response.isEmpty {
                        break
                    }
                    throw NSError(domain: "cmux.remote.relay", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "timed out waiting for local cmux response",
                    ])
                }
                throw NSError(domain: "cmux.remote.relay", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "failed to read local cmux response",
                ])
            }
            return response
        }
    }
}
