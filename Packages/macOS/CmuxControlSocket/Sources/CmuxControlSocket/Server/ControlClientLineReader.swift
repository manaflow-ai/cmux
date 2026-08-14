internal import Darwin
internal import Dispatch
internal import Foundation

/// Blocking newline-framed reader for one accepted control-socket client,
/// lifted byte-faithfully from the legacy `TerminalController.handleClient`
/// read loop.
///
/// One instance serves one connection on one dedicated client-handler thread;
/// the type is intentionally not thread-safe. The reader never closes the
/// descriptor — connection ownership stays with the handler.
///
/// Framing contract (pinned by tests):
/// - Reads up to `bufferSize - 1` bytes per `read(2)` call.
/// - Raw bytes are assembled across reads before decoding, so UTF-8 scalars may
///   span arbitrary transport chunk boundaries. A completed line that is not
///   valid UTF-8 is dropped without discarding any following lines.
/// - Lines are split on bare `\n` only. To preserve legacy framing, `\r\n`
///   does not terminate a line (clients must frame with bare `\n`). Returned
///   lines may be empty or whitespace-only.
/// - `shouldContinueReading` is consulted before each blocking `read(2)`. It
///   is never polled between lines already buffered.
/// - Authorization revocation wakes idle readers through a pollable signal;
///   readers do not periodically wake just to recheck authorization.
/// - The socket's configured `SO_RCVTIMEO` remains the maximum time spent
///   waiting for each next read even though readiness polling precedes `read(2)`.
/// - EOF, a read error, or a `false` poll ends the stream (`nil`); buffered
///   bytes without a trailing newline are discarded, as before.
/// - While `initialLimits` remain active, raw bytes are counted cumulatively
///   before UTF-8 decoding, including invalid lines and line delimiters, and
///   the absolute deadline is checked before buffered lines are returned.
public final class ControlClientLineReader {
    private let socket: Int32
    private var buffer: [UInt8]
    private var pendingBytes: [UInt8] = []
    private var pendingStartIndex = 0
    private var newlineSearchIndex = 0
    private var limitedBytesRead = 0
    private var limits: ControlClientLineReadLimits?
    private var deadlineUptimeNanoseconds: UInt64?
    private let idleReadTimeoutNanoseconds: UInt64?
    private var idleReadDeadlineUptimeNanoseconds: UInt64?
    private let codeRouterHandshakeMaximumBytes: Int?
    private var didCompleteCodeRouterHandshake = false
    private var awaitsCodeRouterHandoffCompletion = false
    private var codeRouterCompletionDeadlineUptimeNanoseconds: UInt64?
    private var currentLineMethodIsCodeRouter: Bool?
    private var lateRouteScanState: LateRouteScanState?
    private let authorizationRevocationSignal: SocketAuthorizationRevocationSignal?
    /// Reused because `poll(2)` rewrites `revents` on every wait.
    private var readinessPollDescriptors: [pollfd]
    private let monotonicNowNanoseconds: @Sendable () -> UInt64

    /// Creates a reader for `socket`.
    /// - Parameters:
    ///   - socket: The connection's descriptor; not closed by the reader.
    ///   - bufferSize: Read buffer size; the legacy loop read at most
    ///     `bufferSize - 1` bytes per call.
    ///   - initialLimits: Optional resource bounds removed after authorization.
    ///   - authorizationRevocationSignal: Signal that wakes an idle reader
    ///     when its accepted authorization generation is revoked.
    ///   - monotonicNowNanoseconds: Monotonic time source used for deadlines.
    public init(
        socket: Int32,
        bufferSize: Int = 4096,
        initialLimits: ControlClientLineReadLimits? = nil,
        authorizationRevocationSignal: SocketAuthorizationRevocationSignal? = nil,
        monotonicNowNanoseconds: (@Sendable () -> UInt64)? = nil,
        codeRouterHandshakeMaximumBytes: Int? = nil
    ) {
        self.socket = socket
        self.buffer = [UInt8](repeating: 0, count: bufferSize)
        self.authorizationRevocationSignal = authorizationRevocationSignal
        self.codeRouterHandshakeMaximumBytes = codeRouterHandshakeMaximumBytes
        var readinessPollDescriptors = [
            pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
        ]
        if let readFileDescriptor = authorizationRevocationSignal?.readFileDescriptor,
           readFileDescriptor >= 0 {
            readinessPollDescriptors.append(
                pollfd(fd: readFileDescriptor, events: Int16(POLLIN), revents: 0)
            )
        }
        self.readinessPollDescriptors = readinessPollDescriptors
        self.monotonicNowNanoseconds = monotonicNowNanoseconds ?? {
            DispatchTime.now().uptimeNanoseconds
        }
        self.idleReadTimeoutNanoseconds = {
            var timeout = timeval()
            var length = socklen_t(MemoryLayout<timeval>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, &length) == 0,
                  timeout.tv_sec >= 0,
                  timeout.tv_usec >= 0,
                  timeout.tv_sec > 0 || timeout.tv_usec > 0 else {
                return nil
            }
            let (seconds, secondsOverflowed) = UInt64(timeout.tv_sec)
                .multipliedReportingOverflow(by: 1_000_000_000)
            let (microseconds, microsecondsOverflowed) = UInt64(timeout.tv_usec)
                .multipliedReportingOverflow(by: 1_000)
            let (total, additionOverflowed) = seconds.addingReportingOverflow(microseconds)
            return secondsOverflowed || microsecondsOverflowed || additionOverflowed ? .max : total
        }()
        self.idleReadDeadlineUptimeNanoseconds = nil
        limits = initialLimits
        if let initialLimits {
            let milliseconds = UInt64(clamping: max(0, initialLimits.timeoutMilliseconds))
            let (duration, overflowed) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
            let now = self.monotonicNowNanoseconds()
            let (deadline, additionOverflowed) = now.addingReportingOverflow(duration)
            deadlineUptimeNanoseconds = overflowed || additionOverflowed ? .max : deadline
        }
    }

    /// Removes preauthorization limits after the peer proves authorization.
    public func clearLimits() {
        limits = nil
        limitedBytesRead = 0
        deadlineUptimeNanoseconds = nil
    }

    /// Allows exactly one completion frame after a CodeRouter begin frame.
    /// The route-specific raw limit remains active for the second frame.
    public func allowCodeRouterHandoffCompletion(
        timeoutMilliseconds: Int
    ) {
        guard didCompleteCodeRouterHandshake,
              !awaitsCodeRouterHandoffCompletion else {
            return
        }
        let milliseconds = UInt64(clamping: max(0, timeoutMilliseconds))
        let (duration, durationOverflowed) = milliseconds
            .multipliedReportingOverflow(by: 1_000_000)
        let (deadline, deadlineOverflowed) = monotonicNowNanoseconds()
            .addingReportingOverflow(duration)
        codeRouterCompletionDeadlineUptimeNanoseconds =
            durationOverflowed || deadlineOverflowed ? .max : deadline
        awaitsCodeRouterHandoffCompletion = true
        didCompleteCodeRouterHandshake = false
    }

    /// Returns the next newline-terminated line (without the newline), or
    /// `nil` when the connection ended or `shouldContinueReading` returned
    /// `false` before a blocking read.
    /// - Parameter shouldContinueReading: Polled before each `read(2)`.
    public func nextLine(shouldContinueReading: () -> Bool) -> String? {
        if didCompleteCodeRouterHandshake {
            return nil
        }
        var startedReadWait = false
        while true {
            guard deadlineHasNotExpired else { return nil }
            inspectCurrentLineMethodIfNeeded()
            guard currentLineIsWithinCodeRouterHandshakeLimit else {
                return nil
            }

            if let newlineIndex = nextBareNewlineIndex() {
                let wasAwaitingCompletion =
                    awaitsCodeRouterHandoffCompletion
                let completedCodeRouterHandshake =
                    currentLineMethodIsCodeRouter == true
                let decodedLine = String(
                    bytes: pendingBytes[pendingStartIndex..<newlineIndex],
                    encoding: .utf8
                )
                pendingStartIndex = newlineIndex + 1
                newlineSearchIndex = pendingStartIndex
                compactPendingBytesIfNeeded()
                currentLineMethodIsCodeRouter = nil
                lateRouteScanState = nil
                if wasAwaitingCompletion {
                    awaitsCodeRouterHandoffCompletion = false
                    codeRouterCompletionDeadlineUptimeNanoseconds = nil
                    didCompleteCodeRouterHandshake = true
                } else {
                    didCompleteCodeRouterHandshake =
                        completedCodeRouterHandshake
                }
                guard let decodedLine else {
                    if didCompleteCodeRouterHandshake { return nil }
                    continue
                }
                return decodedLine
            }

            if !startedReadWait {
                resetIdleReadDeadline()
                startedReadWait = true
            }
            guard waitForReadReadinessBeforeDeadline(
                shouldContinueReading: shouldContinueReading
            ) else { return nil }
            guard let permittedReadCount = codeRouterPermittedReadCount else {
                return nil
            }
            let bytesRead = read(
                socket,
                &buffer,
                min(buffer.count - 1, permittedReadCount)
            )
            guard bytesRead > 0 else { return nil }
            resetIdleReadDeadline()

            if let limits {
                let (totalBytesRead, overflowed) = limitedBytesRead.addingReportingOverflow(bytesRead)
                guard !overflowed, totalBytesRead <= limits.maximumBytes else { return nil }
                limitedBytesRead = totalBytesRead
            }

            // Once an early ordinary method is known, inspect later chunks
            // before appending them. A duplicate handoff method after byte
            // 4096 is rejected without allocating the full ambiguous line.
            guard !lateCodeRouterRouteAppears(inReadCount: bytesRead) else {
                return nil
            }
            pendingBytes.append(contentsOf: buffer[0..<bytesRead])
            inspectCurrentLineMethodIfNeeded()
            guard currentLineIsWithinCodeRouterHandshakeLimit else { return nil }
        }
    }

    /// A route-specific pre-JSON guard. Ordinary v1 lines and v2 methods whose
    /// method key appears early keep the legacy 4 MiB preauthorization limit.
    /// A CodeRouter arm/handoff line is capped before JSON allocation, even
    /// when the peer is a cmux descendant and would otherwise have no initial
    /// line limit. If a JSON method is hidden beyond the cap, fail closed.
    private var currentLineIsWithinCodeRouterHandshakeLimit: Bool {
        guard let maximum = codeRouterHandshakeMaximumBytes else {
            return true
        }
        let newlineIndex = pendingBytes[pendingStartIndex...]
            .firstIndex(of: 0x0A)
        let lineEnd = newlineIndex ?? pendingBytes.endIndex
        let rawCount = lineEnd - pendingStartIndex
            + (newlineIndex == nil ? 0 : 1)
        guard rawCount > maximum else { return true }
        return !awaitsCodeRouterHandoffCompletion
            && currentLineMethodIsCodeRouter == false
    }

    /// Limits reads while the route is undecided or known to be CodeRouter.
    /// This prevents the default 4095-byte read from growing a handoff buffer
    /// from 4095 to about 8190 bytes before the cap is checked.
    private var codeRouterPermittedReadCount: Int? {
        guard let maximum = codeRouterHandshakeMaximumBytes,
              awaitsCodeRouterHandoffCompletion
                || currentLineMethodIsCodeRouter != false else {
            return Int.max
        }
        let newlineIndex = pendingBytes[pendingStartIndex...]
            .firstIndex(of: 0x0A)
        let lineEnd = newlineIndex ?? pendingBytes.endIndex
        let rawCount = lineEnd - pendingStartIndex
            + (newlineIndex == nil ? 0 : 1)
        let remaining = maximum - rawCount
        return remaining > 0 ? remaining : nil
    }

    private func lateCodeRouterRouteAppears(inReadCount bytesRead: Int) -> Bool {
        guard let maximum = codeRouterHandshakeMaximumBytes,
              currentLineMethodIsCodeRouter == false,
              pendingBytes.count - pendingStartIndex + bytesRead > maximum else {
            return false
        }
        var state = lateRouteScanState ?? LateRouteScanState()
        if lateRouteScanState == nil {
            var previous: UInt8?
            for byte in pendingBytes[pendingStartIndex...] {
                if byte == 0x0A, previous != 0x0D { break }
                if state.consume(byte) { return true }
                previous = byte
            }
        }
        var previous = pendingBytes.last
        for byte in buffer[0..<bytesRead] {
            if byte == 0x0A, previous != 0x0D { break }
            if state.consume(byte) { return true }
            previous = byte
        }
        lateRouteScanState = state
        return false
    }

    /// Streaming top-level-key scanner for an already-classified ordinary
    /// line. It rejects a second `method` key, including an escaped value, and
    /// rejects ambiguous escaped top-level keys. This avoids copying or
    /// appending an oversized line before the route is known.
    private struct LateRouteScanState {
        private static let method = Array("method".utf8)

        private var depth = 0
        private var isInsideString = false
        private var isEscaping = false
        private var stringDepth = 0
        private var stringIndex = 0
        private var stringMatchesMethod = true
        private var stringHadEscape = false
        private var hasPendingTopLevelString = false
        private var pendingStringIsMethod = false
        private var pendingStringHadEscape = false
        private var methodKeyCount = 0

        mutating func consume(_ byte: UInt8) -> Bool {
            if isInsideString {
                if isEscaping {
                    isEscaping = false
                    stringHadEscape = true
                    stringMatchesMethod = false
                    return false
                }
                if byte == 0x5C {
                    isEscaping = true
                    return false
                }
                if byte == 0x22 {
                    isInsideString = false
                    if stringDepth == 1 {
                        hasPendingTopLevelString = true
                        pendingStringIsMethod = stringMatchesMethod
                            && stringIndex == Self.method.count
                        pendingStringHadEscape = stringHadEscape
                    }
                    return false
                }
                if stringMatchesMethod {
                    if stringIndex >= Self.method.count
                        || byte != Self.method[stringIndex] {
                        stringMatchesMethod = false
                    }
                }
                stringIndex += 1
                return false
            }

            if hasPendingTopLevelString {
                if ControlClientLineReader.isASCIIWhitespace(byte) {
                    return false
                }
                defer {
                    hasPendingTopLevelString = false
                    pendingStringIsMethod = false
                    pendingStringHadEscape = false
                }
                if byte == 0x3A {
                    if pendingStringHadEscape { return true }
                    if pendingStringIsMethod {
                        methodKeyCount += 1
                        if methodKeyCount > 1 { return true }
                    }
                    return false
                }
            }

            switch byte {
            case 0x22:
                isInsideString = true
                isEscaping = false
                stringDepth = depth
                stringIndex = 0
                stringMatchesMethod = true
                stringHadEscape = false
            case 0x7B, 0x5B:
                depth += 1
            case 0x7D, 0x5D:
                depth = max(0, depth - 1)
            default:
                break
            }
            return false
        }
    }

    private func inspectCurrentLineMethodIfNeeded() {
        guard currentLineMethodIsCodeRouter != true,
              codeRouterHandshakeMaximumBytes != nil else {
            return
        }
        let maximum = codeRouterHandshakeMaximumBytes ?? 0
        let lineEnd = pendingBytes[pendingStartIndex...].firstIndex(of: 0x0A)
            ?? pendingBytes.endIndex
        let bytes = Array(pendingBytes[pendingStartIndex..<lineEnd]
            .prefix(maximum + 1))
        currentLineMethodIsCodeRouter = Self.classifyTopLevelMethod(in: bytes)
    }

    /// Finds an unescaped top-level `method` key without decoding JSON.
    /// Looking only at top-level string tokens prevents a value such as
    /// `{"padding":"\\\"method\\\":\\\"normal\\\""}` from disabling the
    /// CodeRouter cap. Escaped keys and values stay undecided and fail closed
    /// at the cap.
    private static func classifyTopLevelMethod(in bytes: [UInt8]) -> Bool? {
        guard let commandStart = bytes.firstIndex(where: {
            !Self.isASCIIWhitespace($0)
        }) else {
            return nil
        }
        var commandBytes = bytes[commandStart...]
        let capabilityPrefix = Array(
            (SocketClientCapabilityCommand.wirePrefix + " ").utf8
        )
        if commandBytes.starts(with: capabilityPrefix) {
            let capabilityStart = commandBytes.startIndex
                + capabilityPrefix.count
            guard let separator = commandBytes[capabilityStart...]
                .firstIndex(of: 0x20),
                  separator + 1 < commandBytes.endIndex else {
                return nil
            }
            commandBytes = commandBytes[(separator + 1)...]
        }
        guard commandBytes.first == 0x7B else {
            // The handler applies Foundation Unicode whitespace trimming.
            // A non-ASCII prefix can therefore become a JSON route later.
            // Keep it undecided so it cannot disable this pre-JSON cap.
            if let first = commandBytes.first, first >= 0x80 {
                return nil
            }
            return false
        }
        let methodKey = Array("method".utf8)
        var sawOrdinaryMethod = false
        var sawAmbiguousTopLevelKey = false
        var methodKeyCount = 0
        var depth = 0
        var index = commandBytes.startIndex
        while index < commandBytes.endIndex {
            let byte = commandBytes[index]
            if byte == 0x7B || byte == 0x5B {
                depth += 1
                index += 1
                continue
            }
            if byte == 0x7D || byte == 0x5D {
                depth = max(0, depth - 1)
                index += 1
                continue
            }
            guard byte == 0x22 else {
                index += 1
                continue
            }

            let stringStart = index + 1
            index = stringStart
            var escaped = false
            while index < commandBytes.endIndex {
                if commandBytes[index] == 0x5C {
                    escaped = true
                    index += 2
                    continue
                }
                if commandBytes[index] == 0x22 { break }
                index += 1
            }
            guard index < commandBytes.endIndex else {
                return sawOrdinaryMethod ? false : nil
            }
            let stringEnd = index
            index += 1

            guard depth == 1 else {
                continue
            }
            var valueIndex = index
            while valueIndex < commandBytes.endIndex,
                  Self.isASCIIWhitespace(commandBytes[valueIndex]) {
                valueIndex += 1
            }
            guard valueIndex < commandBytes.endIndex,
                  commandBytes[valueIndex] == 0x3A else {
                continue
            }
            if escaped {
                sawAmbiguousTopLevelKey = true
                continue
            }
            guard commandBytes[stringStart..<stringEnd]
                .elementsEqual(methodKey) else {
                continue
            }
            methodKeyCount += 1
            guard methodKeyCount == 1 else {
                return nil
            }
            valueIndex += 1
            while valueIndex < commandBytes.endIndex,
                  Self.isASCIIWhitespace(commandBytes[valueIndex]) {
                valueIndex += 1
            }
            guard valueIndex < commandBytes.endIndex,
                  commandBytes[valueIndex] == 0x22 else {
                return nil
            }
            valueIndex += 1
            let valueStart = valueIndex
            var valueEscaped = false
            while valueIndex < commandBytes.endIndex {
                if commandBytes[valueIndex] == 0x5C {
                    valueEscaped = true
                    valueIndex += 2
                    continue
                }
                if commandBytes[valueIndex] == 0x22 { break }
                valueIndex += 1
            }
            guard valueIndex < commandBytes.endIndex else {
                return nil
            }
            if valueEscaped {
                return nil
            }
            let method = String(
                bytes: commandBytes[valueStart..<valueIndex],
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if method == "coderouter.handoff"
                || method == "coderouter.handoff.arm"
                || method == "coderouter.handoff.begin"
                || method == "coderouter.handoff.complete" {
                return true
            }
            sawOrdinaryMethod = true
            index = valueIndex + 1
        }
        guard !sawAmbiguousTopLevelKey else { return nil }
        return sawOrdinaryMethod ? false : nil
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0B || byte == 0x0C
            || byte == 0x0D || byte == 0x20
    }

    private var deadlineHasNotExpired: Bool {
        let now = monotonicNowNanoseconds()
        if let deadlineUptimeNanoseconds,
           now >= deadlineUptimeNanoseconds {
            return false
        }
        if let codeRouterCompletionDeadlineUptimeNanoseconds,
           now >= codeRouterCompletionDeadlineUptimeNanoseconds {
            return false
        }
        return true
    }

    private func nextBareNewlineIndex() -> Int? {
        while newlineSearchIndex < pendingBytes.count {
            let index = newlineSearchIndex
            newlineSearchIndex += 1
            guard pendingBytes[index] == 0x0A else { continue }
            if index > pendingStartIndex, pendingBytes[index - 1] == 0x0D {
                continue
            }
            return index
        }
        return nil
    }

    private func compactPendingBytesIfNeeded() {
        guard pendingStartIndex > 0 else { return }
        if pendingStartIndex == pendingBytes.count {
            pendingBytes.removeAll(keepingCapacity: true)
            pendingStartIndex = 0
            newlineSearchIndex = 0
            return
        }
        guard pendingStartIndex >= buffer.count,
              pendingStartIndex >= pendingBytes.count / 2 else { return }
        pendingBytes.removeFirst(pendingStartIndex)
        newlineSearchIndex -= pendingStartIndex
        pendingStartIndex = 0
    }

    private func waitForReadReadinessBeforeDeadline(
        shouldContinueReading: () -> Bool
    ) -> Bool {
        while true {
            guard shouldContinueReading(),
                  let timeoutMilliseconds = nextReadinessPollTimeoutMilliseconds() else {
                return false
            }
            readinessPollDescriptors[0].revents = 0
            if readinessPollDescriptors.count == 2 {
                readinessPollDescriptors[1].revents = 0
            }
            let result = readinessPollDescriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), timeoutMilliseconds)
            }
            if result > 0 {
                if readinessPollDescriptors.count == 2,
                   readinessPollDescriptors[1].revents != 0 {
                    return false
                }
                return readinessPollDescriptors[0].revents & Int16(POLLIN | POLLHUP) != 0
            }
            if result == 0 { continue }
            guard errno == EINTR else { return false }
        }
    }

    private func nextReadinessPollTimeoutMilliseconds() -> Int32? {
        let nextDeadline = [
            deadlineUptimeNanoseconds,
            idleReadDeadlineUptimeNanoseconds,
            codeRouterCompletionDeadlineUptimeNanoseconds,
        ].compactMap { $0 }.min()
        guard let nextDeadline else {
            return -1
        }
        let now = monotonicNowNanoseconds()
        guard now < nextDeadline else { return nil }
        let remaining = nextDeadline - now
        let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
        return Int32(min(milliseconds, UInt64(Int32.max)))
    }

    private func resetIdleReadDeadline() {
        guard let idleReadTimeoutNanoseconds else {
            idleReadDeadlineUptimeNanoseconds = nil
            return
        }
        let (deadline, overflowed) = monotonicNowNanoseconds().addingReportingOverflow(
            idleReadTimeoutNanoseconds
        )
        idleReadDeadlineUptimeNanoseconds = overflowed ? .max : deadline
    }
}
