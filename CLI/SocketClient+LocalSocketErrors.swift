import Foundation
import Darwin

extension SocketClient {
    enum SocketWriteFailureContext {
        case localCommand
        case relay
    }

    func recoveredLocalSocketWriteFailure(errorCode: Int32, failureContext: SocketWriteFailureContext) -> String? {
        guard relayEndpoint == nil, failureContext == .localCommand else {
            return nil
        }
        guard errorCode == EPIPE || errorCode == ECONNRESET else {
            return nil
        }

        if let serverMessage = readEarlySocketResponseLine(timeout: 0.15) {
            return serverMessage
        }

        return "cmux socket server closed the connection before reading the command"
    }

    private func readEarlySocketResponseLine(timeout: TimeInterval) -> String? {
        do {
            try configureReceiveTimeout(timeout)
        } catch {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while data.count < 16 * 1024 {
            let count = Darwin.read(socketFD, &buffer, buffer.count)
            if count < 0 {
                let readErrno = errno
                if readErrno == EINTR {
                    continue
                }
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            if data.contains(UInt8(0x0A)) {
                break
            }
        }

        guard var response = String(data: data, encoding: .utf8) else {
            return nil
        }
        if let newlineIndex = response.firstIndex(of: "\n") {
            response = String(response[..<newlineIndex])
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func configureReceiveTimeout(_ timeout: TimeInterval) throws {
        var interval = Self.socketTimeval(for: timeout)
        let result = withUnsafePointer(to: &interval) { ptr in
            setsockopt(
                socketFD,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw CLIError(message: "Failed to configure socket receive timeout")
        }
    }
}
