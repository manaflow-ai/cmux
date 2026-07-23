import Darwin
import Foundation

extension SocketClient {
    /// Sends newline-delimited requests before awaiting their one-line responses.
    func sendSingleLineBatch(
        commands: [String],
        responseTimeout: TimeInterval
    ) throws -> [String] {
        guard !commands.isEmpty else { return [] }
        let deadline = Date.now.addingTimeInterval(responseTimeout)
        if isRelayBacked {
            var responses: [String] = []
            responses.reserveCapacity(commands.count)
            for command in commands {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.socket.error.commandTimedOut",
                        defaultValue: "Command timed out"
                    ))
                }
                try connectWithoutRetry(responseTimeout: remaining)
                let responseRemaining = deadline.timeIntervalSinceNow
                guard responseRemaining > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.socket.error.commandTimedOut",
                        defaultValue: "Command timed out"
                    ))
                }
                responses.append(try send(command: command, responseTimeout: responseRemaining))
            }
            return responses
        }
        guard socketFD >= 0 else {
            throw CLIError(message: String(
                localized: "cli.socket.error.notConnected",
                defaultValue: "Not connected"
            ))
        }

        let payload = commands
            .map { capabilityWrappedCommand($0) + "\n" }
            .joined()
        try configureSocketWriteSafety(responseTimeout)
        try writeAllNonBlocking(
            Data(payload.utf8),
            deadline: deadline,
            timeoutMessage: String(
                localized: "cli.socket.error.commandTimedOut",
                defaultValue: "Command timed out"
            ),
            failureMessage: String(
                localized: "cli.socket.error.failedToWrite",
                defaultValue: "Failed to write to socket"
            )
        )

        var buffer = Data()
        var responses: [String] = []
        responses.reserveCapacity(commands.count)
        while responses.count < commands.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CLIError(message: String(
                    localized: "cli.socket.error.commandTimedOut",
                    defaultValue: "Command timed out"
                ))
            }
            try configureReceiveTimeout(remaining)

            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(socketFD, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw CLIError(message: String(
                        localized: "cli.socket.error.commandTimedOut",
                        defaultValue: "Command timed out"
                    ))
                }
                throw CLIError(message: String(
                    localized: "cli.socket.error.socketRead",
                    defaultValue: "Socket read error"
                ))
            }
            guard count > 0 else {
                throw CLIError(message: String(
                    localized: "cli.socket.error.socketClosedBeforeCompleteReply",
                    defaultValue: "Socket closed before complete reply"
                ))
            }
            buffer.append(chunk, count: count)
            guard buffer.count <= 8 * 1024 * 1024 else {
                throw CLIError(message: String(
                    localized: "cli.socket.error.responseExceededBatchLimit",
                    defaultValue: "Socket response exceeded batch limit"
                ))
            }

            while responses.count < commands.count,
                  let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                guard !line.isEmpty,
                      let response = String(data: line, encoding: .utf8) else {
                    throw CLIError(message: String(
                        localized: "cli.socket.error.invalidUTF8Response",
                        defaultValue: "Invalid UTF-8 response"
                    ))
                }
                responses.append(response)
                buffer.removeSubrange(...newline)
            }
        }

        guard buffer.allSatisfy({ $0 == 0x0A || $0 == 0x0D || $0 == 0x20 || $0 == 0x09 }) else {
            throw CLIError(message: String(
                localized: "cli.socket.error.unexpectedExtraBatchResponse",
                defaultValue: "Unexpected extra batched socket response"
            ))
        }
        return responses
    }
}
