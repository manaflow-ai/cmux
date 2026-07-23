import CryptoKit
import Darwin
import Foundation

/// A validated snapshot written by the local computer-use driver.
struct ComputerUseDriverState: Equatable, Sendable {
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSecondISO8601 = Date.ISO8601FormatStyle(
        includingFractionalSeconds: false
    )
    private static let authenticationDomain = Data(
        "cmux-computer-use-state-v1\0".utf8
    )

    let pid: Int
    /// The kernel-authenticated proxy generation that issued this action.
    let writerProcessIdentity: AgentPIDProcessIdentity
    var writerPID: Int { Int(writerProcessIdentity.pid) }
    /// The driver's own session id when one was declared; `null` in the file
    /// for cursor-less runs, and never equal to the cmux hook session id.
    let session: String?
    let targetApp: String
    let targetPID: Int
    let targetWindowID: UInt32
    let lastActionAt: Date

    init?(data: Data, authenticationKey: Data) {
        guard
            authenticationKey.count == 32,
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            let schema = Self.positiveInt(dictionary["schema"]),
            schema == 4,
            // The driver writes "driver_pid"; accept legacy "pid" only for
            // daemon display identity. Trusted state provenance is schema 4.
            let pid = Self.positiveInt(dictionary["driver_pid"] ?? dictionary["pid"]),
            let writerPID = Self.positiveInt(dictionary["writer_pid"]),
            let writerPIDValue = pid_t(exactly: writerPID),
            let writerStartSeconds = Self.boundedInt64(
                dictionary["writer_start_seconds"],
                minimum: 1,
                maximum: Int64.max
            ),
            let writerStartMicroseconds = Self.boundedInt64(
                dictionary["writer_start_microseconds"],
                minimum: 0,
                maximum: 999_999
            ),
            let targetApp = Self.boundedNonemptyString(dictionary["target_app"], maximumUTF8Bytes: 1_024),
            let targetPID = Self.positiveInt(dictionary["target_pid"]),
            let targetWindowInt = Self.positiveInt(dictionary["target_window_id"]),
            targetWindowInt <= Int(UInt32.max),
            let lastActionValue = Self.boundedNonemptyString(
                dictionary["last_action_at"],
                maximumUTF8Bytes: 128
            ),
            let lastActionAt = Self.date(lastActionValue),
            let authenticationCode = Self.hexData(
                dictionary["state_authentication_code"],
                expectedByteCount: SHA256.byteCount
            )
        else {
            return nil
        }

        let session = Self.boundedNonemptyString(
            dictionary["session"],
            maximumUTF8Bytes: 1_024
        )
        let message = Self.authenticationMessage(
            pid: pid,
            writerPID: writerPID,
            writerStartSeconds: writerStartSeconds,
            writerStartMicroseconds: writerStartMicroseconds,
            session: session,
            targetApp: targetApp,
            targetPID: targetPID,
            targetWindowID: targetWindowInt,
            lastActionAt: lastActionValue,
            schema: schema
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(
            authenticationCode,
            authenticating: message,
            using: SymmetricKey(data: authenticationKey)
        ) else {
            return nil
        }

        self.pid = pid
        self.writerProcessIdentity = AgentPIDProcessIdentity(
            pid: writerPIDValue,
            startSeconds: writerStartSeconds,
            startMicroseconds: writerStartMicroseconds
        )
        self.session = session
        self.targetApp = targetApp
        self.targetPID = targetPID
        self.targetWindowID = UInt32(targetWindowInt)
        self.lastActionAt = lastActionAt
    }

    private static func authenticationMessage(
        pid: Int,
        writerPID: Int,
        writerStartSeconds: Int64,
        writerStartMicroseconds: Int64,
        session: String?,
        targetApp: String,
        targetPID: Int,
        targetWindowID: Int,
        lastActionAt: String,
        schema: Int
    ) -> Data {
        var message = authenticationDomain
        appendInteger(pid, to: &message)
        appendInteger(writerPID, to: &message)
        appendInteger(writerStartSeconds, to: &message)
        appendInteger(writerStartMicroseconds, to: &message)
        appendOptionalString(session, to: &message)
        appendOptionalString(targetApp, to: &message)
        appendInteger(targetPID, to: &message)
        appendInteger(targetWindowID, to: &message)
        appendString(lastActionAt, to: &message)
        appendInteger(schema, to: &message)
        return message
    }

    private static func appendInteger<T: BinaryInteger>(
        _ value: T,
        to message: inout Data
    ) {
        message.append(contentsOf: String(value).utf8)
        message.append(0)
    }

    private static func appendString(_ value: String, to message: inout Data) {
        let bytes = Data(value.utf8)
        message.append(contentsOf: String(bytes.count).utf8)
        message.append(UInt8(ascii: ":"))
        message.append(bytes)
        message.append(0)
    }

    private static func appendOptionalString(
        _ value: String?,
        to message: inout Data
    ) {
        guard let value else {
            message.append(contentsOf: [UInt8(ascii: "-"), 0])
            return
        }
        appendString(value, to: &message)
    }

    /// Validates that the process which wrote this state is still rooted in the
    /// live agent process tree. This is a bounded point lookup, not a
    /// machine-wide process scan.
    func belongsToProcessTree(
        rootProcessIdentities: Set<AgentPIDProcessIdentity>
    ) -> Bool {
        Self.process(
            writerProcessIdentity,
            belongsToProcessTree: rootProcessIdentities
        )
    }

    static func process(
        _ processIdentity: AgentPIDProcessIdentity,
        belongsToProcessTree rootProcessIdentities: Set<AgentPIDProcessIdentity>
    ) -> Bool {
        guard !rootProcessIdentities.isEmpty else { return false }
        var currentPID = processIdentity.pid
        var expectedIdentity: AgentPIDProcessIdentity? = processIdentity
        var visited: Set<pid_t> = []

        for _ in 0 ..< 64 {
            guard currentPID > 0, visited.insert(currentPID).inserted else {
                return false
            }
            guard
                let snapshot = AgentPIDProcessIdentity.processSnapshot(pid: currentPID),
                expectedIdentity.map({ $0 == snapshot.identity }) ?? true
            else {
                return false
            }
            if rootProcessIdentities.contains(snapshot.identity) {
                return true
            }

            let parentPID = snapshot.parentPID
            guard parentPID > 0, parentPID != currentPID else { return false }
            currentPID = parentPID
            expectedIdentity = nil
        }
        return false
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        let parsed: Int?
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else { return nil }
            parsed = Int(exactly: doubleValue)
        } else if let string = value as? String {
            parsed = Int(string)
        } else {
            parsed = nil
        }
        guard let parsed, parsed > 0, parsed <= Int(Int32.max) else { return nil }
        return parsed
    }

    private static func boundedInt64(
        _ value: Any?,
        minimum: Int64,
        maximum: Int64
    ) -> Int64? {
        let parsed: Int64?
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded() == doubleValue else { return nil }
            parsed = Int64(exactly: doubleValue)
        } else if let string = value as? String {
            parsed = Int64(string)
        } else {
            parsed = nil
        }
        guard let parsed, (minimum ... maximum).contains(parsed) else { return nil }
        return parsed
    }

    private static func boundedNonemptyString(_ value: Any?, maximumUTF8Bytes: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumUTF8Bytes else { return nil }
        return trimmed
    }

    private static func hexData(
        _ value: Any?,
        expectedByteCount: Int
    ) -> Data? {
        guard
            let string = value as? String,
            string.utf8.count == expectedByteCount * 2
        else {
            return nil
        }
        var result = Data()
        result.reserveCapacity(expectedByteCount)
        var index = string.startIndex
        for _ in 0 ..< expectedByteCount {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index ..< next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, String(cString: number.objCType) != "c" {
            return date(timeInterval: number.doubleValue)
        }
        guard let string = value as? String else { return nil }
        if let numeric = Double(string) {
            return date(timeInterval: numeric)
        }
        if let parsed = try? fractionalISO8601.parse(string) {
            return parsed
        }
        if let parsed = try? wholeSecondISO8601.parse(string) {
            return parsed
        }
        // The driver writes 6-digit fractional seconds (e.g. ".745752Z"), which
        // ISO8601DateFormatter's fractional mode does not accept on all macOS
        // versions; retry with the fraction truncated to milliseconds.
        if let match = string.range(of: #"\.(\d{3})\d+"#, options: .regularExpression) {
            var truncated = string
            let keep = string[match.lowerBound...].prefix(4)
            truncated.replaceSubrange(match, with: keep)
            return try? fractionalISO8601.parse(truncated)
        }
        return nil
    }

    private static func date(timeInterval: TimeInterval) -> Date? {
        guard timeInterval.isFinite, timeInterval > 0 else { return nil }
        let seconds = timeInterval > 10_000_000_000 ? timeInterval / 1_000 : timeInterval
        return Date(timeIntervalSince1970: seconds)
    }
}
