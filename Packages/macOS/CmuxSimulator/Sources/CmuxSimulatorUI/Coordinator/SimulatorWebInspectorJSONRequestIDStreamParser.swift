import Foundation

/// Incrementally extracts one top-level JSON request id without retaining the
/// response body. Strings, escapes, and nested containers may cross chunks.
struct SimulatorWebInspectorJSONRequestIDStreamParser {
    private static let maximumKeyTokenBytes = 64
    private static let maximumIDTokenBytes = 8 * 1_024

    private(set) var requestID: SimulatorWebInspectorJSONRequestID?
    private var started = false
    private var finished = false
    private var depth = 0
    private var expectsTopLevelKey = false
    private var awaitingColon = false
    private var currentKeyIsID = false
    private var awaitingIDValue = false
    private var isInsideString = false
    private var isEscaped = false
    private var stringRole = SimulatorWebInspectorJSONStringRole.other
    private var token = Data()
    private var tokenOverflowed = false
    private var isCapturingScalarID = false
    private var scalarIDToken = Data()

    var retainedByteCount: Int { token.count + scalarIDToken.count }

    mutating func ingest(_ data: Data) {
        for byte in data where requestID == nil && !finished {
            ingest(byte)
        }
    }

    private mutating func ingest(_ byte: UInt8) {
        if isInsideString {
            ingestStringByte(byte)
            return
        }
        if isCapturingScalarID {
            if isSimulatorWebInspectorJSONValueDelimiter(byte) {
                finishScalarID()
            } else {
                appendScalar(byte)
                return
            }
        }
        if !started {
            guard !isSimulatorWebInspectorJSONWhitespace(byte) else { return }
            guard byte == 0x7B else {
                finished = true
                return
            }
            started = true
            depth = 1
            expectsTopLevelKey = true
            return
        }
        if depth == 1, awaitingIDValue, !isSimulatorWebInspectorJSONWhitespace(byte) {
            awaitingIDValue = false
            if byte == 0x22 {
                startString(role: .idValue)
                return
            }
            if byte != 0x7B, byte != 0x5B {
                scalarIDToken = Data([byte])
                isCapturingScalarID = true
                tokenOverflowed = false
                return
            }
        }
        if byte == 0x22 {
            startString(role: depth == 1 && expectsTopLevelKey ? .key : .other)
            return
        }
        switch byte {
        case 0x7B, 0x5B:
            depth += 1
        case 0x7D, 0x5D:
            depth -= 1
            if depth <= 0 { finished = true }
        case 0x3A where depth == 1 && awaitingColon:
            awaitingColon = false
            awaitingIDValue = currentKeyIsID
        case 0x2C where depth == 1:
            expectsTopLevelKey = true
            awaitingColon = false
            awaitingIDValue = false
            currentKeyIsID = false
        default:
            break
        }
    }

    private mutating func startString(role: SimulatorWebInspectorJSONStringRole) {
        isInsideString = true
        isEscaped = false
        stringRole = role
        token.removeAll(keepingCapacity: true)
        tokenOverflowed = false
        if role != .other { token.append(0x22) }
    }

    private mutating func ingestStringByte(_ byte: UInt8) {
        if stringRole != .other {
            let limit = stringRole == .key
                ? Self.maximumKeyTokenBytes
                : Self.maximumIDTokenBytes
            append(byte, maximumCount: limit)
        }
        if isEscaped {
            isEscaped = false
            return
        }
        if byte == 0x5C {
            isEscaped = true
            return
        }
        guard byte == 0x22 else { return }
        isInsideString = false
        switch stringRole {
        case .key:
            let key = tokenOverflowed
                ? nil
                : decodeSimulatorWebInspectorJSONStringToken(token)
            currentKeyIsID = key == "id"
            expectsTopLevelKey = false
            awaitingColon = true
        case .idValue:
            if !tokenOverflowed {
                requestID = parseSimulatorWebInspectorJSONRequestIDToken(token)
            }
        case .other:
            break
        }
        token.removeAll(keepingCapacity: true)
    }

    private mutating func finishScalarID() {
        if !tokenOverflowed {
            requestID = parseSimulatorWebInspectorJSONRequestIDToken(scalarIDToken)
        }
        isCapturingScalarID = false
        scalarIDToken.removeAll(keepingCapacity: true)
        tokenOverflowed = false
    }

    private mutating func append(_ byte: UInt8, maximumCount: Int) {
        guard !tokenOverflowed else { return }
        guard token.count < maximumCount else {
            tokenOverflowed = true
            token.removeAll(keepingCapacity: true)
            return
        }
        token.append(byte)
    }

    private mutating func appendScalar(_ byte: UInt8) {
        guard !tokenOverflowed else { return }
        guard scalarIDToken.count < Self.maximumIDTokenBytes else {
            tokenOverflowed = true
            scalarIDToken.removeAll(keepingCapacity: true)
            return
        }
        scalarIDToken.append(byte)
    }

}

private func isSimulatorWebInspectorJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

private func isSimulatorWebInspectorJSONValueDelimiter(_ byte: UInt8) -> Bool {
    isSimulatorWebInspectorJSONWhitespace(byte) || byte == 0x2C || byte == 0x7D || byte == 0x5D
}
