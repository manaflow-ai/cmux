public import Foundation

extension CmuxAgentSessionRegistry {
    /// Structural size metadata collected before Foundation materializes a
    /// compatibility JSON object graph.
    public struct HookLegacySourceMetrics: Equatable, Sendable {
        /// Unique direct records in the wrapped `sessions` object or flat root.
        public var sessionCount: Int
        /// Unique canonical runs, with one fallback node for a session without runs.
        public var graphNodeCount: Int
        /// Largest encoded direct session value.
        public var largestRecordBytes: Int64
        /// Session owning `largestRecordBytes`.
        public var largestRecordSessionID: String?

        /// Creates compatibility-file structural metrics.
        public init(
            sessionCount: Int,
            graphNodeCount: Int,
            largestRecordBytes: Int64,
            largestRecordSessionID: String?
        ) {
            self.sessionCount = sessionCount
            self.graphNodeCount = graphNodeCount
            self.largestRecordBytes = largestRecordBytes
            self.largestRecordSessionID = largestRecordSessionID
        }
    }

    /// A compatibility file exceeded a structural limit before JSON decoding.
    public struct HookLegacySourceInspectionLimitError: Error, Equatable, Sendable {
        /// Structural resource that exceeded its limit.
        public enum Scope: String, Equatable, Sendable {
            /// Unique direct session entries.
            case sessions
            /// Canonical graph nodes after per-session run de-duplication.
            case graphNodes = "graph_nodes"
            /// Bytes in one direct session value.
            case recordBytes = "record_bytes"
            /// Bytes in a session or run identifier needed for exact de-duplication.
            case identifierBytes = "identifier_bytes"
        }

        /// Compatibility file path.
        public var path: String
        /// Limit category.
        public var scope: Scope
        /// Session associated with a record-local failure.
        public var sessionID: String?
        /// Minimum observed value.
        public var observed: Int64
        /// Largest accepted value.
        public var maximum: Int64

        /// Creates a structural-limit failure.
        public init(
            path: String,
            scope: Scope,
            sessionID: String? = nil,
            observed: Int64,
            maximum: Int64
        ) {
            self.path = path
            self.scope = scope
            self.sessionID = sessionID
            self.observed = observed
            self.maximum = maximum
        }
    }

    /// A compatibility file was not structurally valid JSON.
    public struct HookLegacySourceMalformedError: Error, Equatable, Sendable {
        /// Compatibility file path.
        public var path: String
        /// Byte offset at which parsing stopped.
        public var offset: Int64

        /// Creates a malformed-source failure.
        public init(path: String, offset: Int64) {
            self.path = path
            self.offset = offset
        }
    }

    /// Scans compatibility JSON before `JSONSerialization` can allocate its
    /// full object graph. Strings, escapes, nesting, duplicate session keys, and
    /// duplicate run IDs are handled with JSON semantics. Both the canonical
    /// `{ "sessions": ... }` layout and older flat session maps are accepted.
    /// Identifier storage is bounded by the record and graph limits.
    public func hookLegacySourceMetrics(
        at url: URL,
        maximumBytes: Int64 = 64 * 1_024 * 1_024,
        maximumSessions: Int = 20_000,
        maximumGraphNodes: Int = 20_000,
        maximumRecordBytes: Int64 = 4 * 1_024 * 1_024
    ) throws -> HookLegacySourceMetrics {
        let data = try readHookLegacySourceDataUnvalidated(at: url, maximumBytes: maximumBytes)
        return try scanHookLegacySourceData(
            data,
            path: url.path,
            maximumSessions: maximumSessions,
            maximumGraphNodes: maximumGraphNodes,
            maximumRecordBytes: maximumRecordBytes
        )
    }

    func scanHookLegacySourceData(
        _ data: Data,
        path: String,
        maximumSessions: Int = 20_000,
        maximumGraphNodes: Int = 20_000,
        maximumRecordBytes: Int64 = 4 * 1_024 * 1_024
    ) throws -> HookLegacySourceMetrics {
        try data.withUnsafeBytes { rawBuffer in
            var scanner = HookLegacyJSONScanner(
                bytes: rawBuffer.bindMemory(to: UInt8.self),
                path: path,
                maximumSessions: max(0, maximumSessions),
                maximumGraphNodes: max(0, maximumGraphNodes),
                maximumRecordBytes: max(0, maximumRecordBytes)
            )
            return try scanner.scan()
        }
    }
}

private struct HookLegacyJSONScanner {
    private struct RecordMetrics {
        var graphNodes: Int
        var bytes: Int64
    }

    let bytes: UnsafeBufferPointer<UInt8>
    let path: String
    let maximumSessions: Int
    let maximumGraphNodes: Int
    let maximumRecordBytes: Int64
    private let maximumNestingDepth = 512
    private let maximumKeyBytes = 1_536
    private let maximumIdentifierBytes = 16 * 1_024
    private var offset = 0

    init(
        bytes: UnsafeBufferPointer<UInt8>,
        path: String,
        maximumSessions: Int,
        maximumGraphNodes: Int,
        maximumRecordBytes: Int64
    ) {
        self.bytes = bytes
        self.path = path
        self.maximumSessions = maximumSessions
        self.maximumGraphNodes = maximumGraphNodes
        self.maximumRecordBytes = maximumRecordBytes
    }

    mutating func scan() throws -> CmuxAgentSessionRegistry.HookLegacySourceMetrics {
        if let wrapped = try scanWrappedSessions() { return wrapped }
        offset = 0
        return try scanFlatRoot()
    }

    private mutating func scanWrappedSessions() throws
        -> CmuxAgentSessionRegistry.HookLegacySourceMetrics? {
        try skipWhitespace()
        try expect(0x7B) // {
        try skipWhitespace()
        var metrics: CmuxAgentSessionRegistry.HookLegacySourceMetrics?
        if consume(0x7D) {
            try skipWhitespace()
            guard offset == bytes.count else { throw malformed() }
            return nil
        }
        while true {
            let key = try parseString(maximumCapturedBytes: maximumKeyBytes, overflowIsError: false)
            try skipWhitespace()
            try expect(0x3A) // :
            try skipWhitespace()
            if key == "sessions", peek() == 0x7B {
                metrics = try parseSessionsObject()
            } else {
                if key == "sessions" { metrics = nil }
                try skipValue(depth: 1)
            }
            try skipWhitespace()
            if consume(0x7D) { break }
            try expect(0x2C) // ,
            try skipWhitespace()
        }
        try skipWhitespace()
        guard offset == bytes.count else { throw malformed() }
        return metrics
    }

    /// Older app-side consumers accepted a root dictionary keyed directly by
    /// session ID. Scalar metadata is validated and counted toward the unique
    /// root-key budget but is not exposed as a record, matching their decode
    /// behavior. Duplicate keys use the last JSON value.
    private mutating func scanFlatRoot() throws -> CmuxAgentSessionRegistry.HookLegacySourceMetrics {
        try skipWhitespace()
        try expect(0x7B)
        try skipWhitespace()
        var directKeys: Set<String> = []
        var records: [String: RecordMetrics] = [:]
        directKeys.reserveCapacity(min(maximumSessions, 8_192))
        records.reserveCapacity(min(maximumSessions, 8_192))
        var totalNodes = 0
        if consume(0x7D) {
            try skipWhitespace()
            guard offset == bytes.count else { throw malformed() }
            return .init(
                sessionCount: 0,
                graphNodeCount: 0,
                largestRecordBytes: 0,
                largestRecordSessionID: nil
            )
        }
        while true {
            guard let sessionID = try parseString(
                maximumCapturedBytes: maximumIdentifierBytes,
                overflowIsError: true
            ) else { throw malformed() }
            directKeys.insert(sessionID)
            try skipWhitespace()
            try expect(0x3A)
            try skipWhitespace()
            let recordStart = offset
            let recordMetrics: RecordMetrics?
            switch peek() {
            case 0x7B:
                let runIDs = try parseSessionRecord(
                    sessionID: sessionID,
                    recordStart: recordStart
                )
                recordMetrics = .init(
                    graphNodes: max(1, runIDs.count),
                    bytes: Int64(offset - recordStart)
                )
            case 0x5B:
                try skipValue(depth: 1)
                recordMetrics = .init(
                    graphNodes: 1,
                    bytes: Int64(offset - recordStart)
                )
            default:
                try skipValue(depth: 1)
                recordMetrics = nil
            }
            if let recordMetrics,
               recordMetrics.bytes > maximumRecordBytes {
                throw limit(
                    .recordBytes,
                    sessionID: sessionID,
                    observed: recordMetrics.bytes,
                    maximum: maximumRecordBytes
                )
            }
            if let previous = records.removeValue(forKey: sessionID) {
                totalNodes -= previous.graphNodes
            }
            if let recordMetrics {
                records[sessionID] = recordMetrics
                totalNodes += recordMetrics.graphNodes
            }
            guard totalNodes <= maximumGraphNodes else {
                throw limit(
                    .graphNodes,
                    observed: Int64(totalNodes),
                    maximum: Int64(maximumGraphNodes)
                )
            }
            guard directKeys.count <= maximumSessions else {
                throw limit(
                    .sessions,
                    observed: Int64(directKeys.count),
                    maximum: Int64(maximumSessions)
                )
            }
            try skipWhitespace()
            if consume(0x7D) { break }
            try expect(0x2C)
            try skipWhitespace()
        }
        try skipWhitespace()
        guard offset == bytes.count else { throw malformed() }
        let largest = records.max {
            if $0.value.bytes != $1.value.bytes { return $0.value.bytes < $1.value.bytes }
            return $0.key > $1.key
        }
        return .init(
            sessionCount: records.count,
            graphNodeCount: totalNodes,
            largestRecordBytes: largest?.value.bytes ?? 0,
            largestRecordSessionID: largest?.key
        )
    }

    private mutating func parseSessionsObject() throws -> CmuxAgentSessionRegistry.HookLegacySourceMetrics {
        try expect(0x7B)
        try skipWhitespace()
        var records: [String: RecordMetrics] = [:]
        records.reserveCapacity(min(maximumSessions, 8_192))
        var totalNodes = 0
        if consume(0x7D) {
            return .init(
                sessionCount: 0,
                graphNodeCount: 0,
                largestRecordBytes: 0,
                largestRecordSessionID: nil
            )
        }
        while true {
            guard let sessionID = try parseString(
                maximumCapturedBytes: maximumIdentifierBytes,
                overflowIsError: true
            ) else { throw malformed() }
            try skipWhitespace()
            try expect(0x3A)
            try skipWhitespace()
            let recordStart = offset
            let runIDs = try parseSessionRecord(sessionID: sessionID, recordStart: recordStart)
            let recordBytes = Int64(offset - recordStart)
            guard recordBytes <= maximumRecordBytes else {
                throw limit(
                    .recordBytes,
                    sessionID: sessionID,
                    observed: recordBytes,
                    maximum: maximumRecordBytes
                )
            }
            let recordMetrics = RecordMetrics(
                graphNodes: max(1, runIDs.count),
                bytes: recordBytes
            )
            if let previous = records.updateValue(recordMetrics, forKey: sessionID) {
                totalNodes -= previous.graphNodes
            }
            totalNodes += recordMetrics.graphNodes
            guard totalNodes <= maximumGraphNodes else {
                throw limit(
                    .graphNodes,
                    observed: Int64(totalNodes),
                    maximum: Int64(maximumGraphNodes)
                )
            }
            guard records.count <= maximumSessions else {
                throw limit(
                    .sessions,
                    observed: Int64(records.count),
                    maximum: Int64(maximumSessions)
                )
            }
            try skipWhitespace()
            if consume(0x7D) { break }
            try expect(0x2C)
            try skipWhitespace()
        }
        let largest = records.max {
            if $0.value.bytes != $1.value.bytes { return $0.value.bytes < $1.value.bytes }
            return $0.key > $1.key
        }
        return .init(
            sessionCount: records.count,
            graphNodeCount: totalNodes,
            largestRecordBytes: largest?.value.bytes ?? 0,
            largestRecordSessionID: largest?.key
        )
    }

    private mutating func parseSessionRecord(
        sessionID: String,
        recordStart: Int
    ) throws -> Set<String> {
        try expect(0x7B)
        try skipWhitespace()
        var runIDs: Set<String> = []
        if consume(0x7D) { return runIDs }
        while true {
            let key = try parseString(maximumCapturedBytes: maximumKeyBytes, overflowIsError: false)
            try skipWhitespace()
            try expect(0x3A)
            try skipWhitespace()
            if key == "runs" {
                runIDs = try parseRuns(sessionID: sessionID)
            } else {
                try skipValue(depth: 2)
            }
            let observedBytes = Int64(offset - recordStart)
            guard observedBytes <= maximumRecordBytes else {
                throw limit(
                    .recordBytes,
                    sessionID: sessionID,
                    observed: observedBytes,
                    maximum: maximumRecordBytes
                )
            }
            try skipWhitespace()
            if consume(0x7D) { break }
            try expect(0x2C)
            try skipWhitespace()
        }
        return runIDs
    }

    private mutating func parseRuns(sessionID: String) throws -> Set<String> {
        if peek() == 0x6E { // null
            try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
            return []
        }
        try expect(0x5B) // [
        try skipWhitespace()
        var runIDs: Set<String> = []
        if consume(0x5D) { return runIDs }
        while true {
            let runID = try parseRunObject(sessionID: sessionID)
            if let runID { runIDs.insert(runID) }
            guard runIDs.count <= maximumGraphNodes else {
                throw limit(
                    .graphNodes,
                    sessionID: sessionID,
                    observed: Int64(runIDs.count),
                    maximum: Int64(maximumGraphNodes)
                )
            }
            try skipWhitespace()
            if consume(0x5D) { break }
            try expect(0x2C)
            try skipWhitespace()
        }
        return runIDs
    }

    private mutating func parseRunObject(sessionID: String) throws -> String? {
        try expect(0x7B)
        try skipWhitespace()
        var runID: String?
        if consume(0x7D) { return nil }
        while true {
            let key = try parseString(maximumCapturedBytes: maximumKeyBytes, overflowIsError: false)
            try skipWhitespace()
            try expect(0x3A)
            try skipWhitespace()
            if key == "runId" {
                if peek() == 0x22 {
                    runID = try parseString(
                        maximumCapturedBytes: maximumIdentifierBytes,
                        overflowIsError: true,
                        sessionID: sessionID
                    )
                } else {
                    try skipValue(depth: 4)
                    runID = nil
                }
            } else {
                try skipValue(depth: 4)
            }
            try skipWhitespace()
            if consume(0x7D) { break }
            try expect(0x2C)
            try skipWhitespace()
        }
        return runID
    }

    private mutating func skipValue(depth: Int) throws {
        guard depth <= maximumNestingDepth, let byte = peek() else { throw malformed() }
        switch byte {
        case 0x7B: // {
            _ = read()
            try skipWhitespace()
            if consume(0x7D) { return }
            while true {
                _ = try parseString(maximumCapturedBytes: nil, overflowIsError: false)
                try skipWhitespace()
                try expect(0x3A)
                try skipWhitespace()
                try skipValue(depth: depth + 1)
                try skipWhitespace()
                if consume(0x7D) { return }
                try expect(0x2C)
                try skipWhitespace()
            }
        case 0x5B: // [
            _ = read()
            try skipWhitespace()
            if consume(0x5D) { return }
            while true {
                try skipValue(depth: depth + 1)
                try skipWhitespace()
                if consume(0x5D) { return }
                try expect(0x2C)
                try skipWhitespace()
            }
        case 0x22:
            _ = try parseString(maximumCapturedBytes: nil, overflowIsError: false)
        case 0x74:
            try parseLiteral([0x74, 0x72, 0x75, 0x65])
        case 0x66:
            try parseLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
        case 0x6E:
            try parseLiteral([0x6E, 0x75, 0x6C, 0x6C])
        case 0x2D, 0x30...0x39:
            try parseNumber()
        default:
            throw malformed()
        }
    }

    private mutating func parseString(
        maximumCapturedBytes: Int?,
        overflowIsError: Bool,
        sessionID: String? = nil
    ) throws -> String? {
        try expect(0x22)
        var captured = maximumCapturedBytes == nil ? nil : [UInt8]()
        captured?.reserveCapacity(min(maximumCapturedBytes ?? 0, 128))
        var overflowed = false
        while let byte = read() {
            if byte == 0x22 {
                guard !overflowed else {
                    if overflowIsError {
                        throw limit(
                            .identifierBytes,
                            sessionID: sessionID,
                            observed: Int64((maximumCapturedBytes ?? 0) + 1),
                            maximum: Int64(maximumCapturedBytes ?? 0)
                        )
                    }
                    return nil
                }
                guard let captured else { return nil }
                var quoted = Data([0x22])
                quoted.append(contentsOf: captured)
                quoted.append(0x22)
                guard let decoded = try? JSONSerialization.jsonObject(
                    with: quoted,
                    options: [.fragmentsAllowed]
                ) as? String else {
                    throw malformed()
                }
                return decoded
            }
            guard byte >= 0x20 else { throw malformed() }
            appendCaptured(byte, to: &captured, limit: maximumCapturedBytes, overflowed: &overflowed)
            if byte == 0x5C { // \
                guard let escaped = read() else { throw malformed() }
                appendCaptured(escaped, to: &captured, limit: maximumCapturedBytes, overflowed: &overflowed)
                switch escaped {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    for _ in 0..<4 {
                        guard let hex = read(), isHexDigit(hex) else { throw malformed() }
                        appendCaptured(hex, to: &captured, limit: maximumCapturedBytes, overflowed: &overflowed)
                    }
                default:
                    throw malformed()
                }
            }
        }
        throw malformed()
    }

    private func appendCaptured(
        _ byte: UInt8,
        to captured: inout [UInt8]?,
        limit: Int?,
        overflowed: inout Bool
    ) {
        guard captured != nil, !overflowed, let limit else { return }
        if captured!.count < limit {
            captured!.append(byte)
        } else {
            captured = nil
            overflowed = true
        }
    }

    private mutating func parseNumber() throws {
        _ = consume(0x2D)
        if consume(0x30) {
            if let byte = peek(), (0x30...0x39).contains(byte) { throw malformed() }
        } else {
            guard let first = peek(), (0x31...0x39).contains(first) else { throw malformed() }
            _ = read()
            while let byte = peek(), (0x30...0x39).contains(byte) { _ = read() }
        }
        if consume(0x2E) {
            guard let first = peek(), (0x30...0x39).contains(first) else { throw malformed() }
            while let byte = peek(), (0x30...0x39).contains(byte) { _ = read() }
        }
        if consume(0x65) || consume(0x45) {
            _ = consume(0x2B) || consume(0x2D)
            guard let first = peek(), (0x30...0x39).contains(first) else { throw malformed() }
            while let byte = peek(), (0x30...0x39).contains(byte) { _ = read() }
        }
    }

    private mutating func parseLiteral(_ literal: [UInt8]) throws {
        for expectedByte in literal { try expect(expectedByte) }
    }

    private mutating func skipWhitespace() throws {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            _ = read()
        }
    }

    private func peek() -> UInt8? {
        offset < bytes.count ? bytes[offset] : nil
    }

    @discardableResult
    private mutating func read() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek() == byte else { return false }
        offset += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard consume(byte) else { throw malformed() }
    }

    private func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }

    private func malformed() -> CmuxAgentSessionRegistry.HookLegacySourceMalformedError {
        .init(path: path, offset: Int64(offset))
    }

    private func limit(
        _ scope: CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError.Scope,
        sessionID: String? = nil,
        observed: Int64,
        maximum: Int64
    ) -> CmuxAgentSessionRegistry.HookLegacySourceInspectionLimitError {
        .init(
            path: path,
            scope: scope,
            sessionID: sessionID,
            observed: observed,
            maximum: maximum
        )
    }
}
