import Foundation

private let maximumWebInspectorJSONKeyBytes = 64
private let maximumWebInspectorJSONIDBytes = 8 * 1_024

/// Incrementally extracts one bounded top-level JSON `id` token without
/// retaining or decoding the response body.
public struct SimulatorWebInspectorRequestIDTokenExtractor: Sendable {
    /// The raw JSON token for the top-level `id`, including quotes for strings.
    public private(set) var requestIDToken: Data?
    private var started = false
    private var finished = false
    private var depth = 0
    private var expectsTopLevelKey = false
    private var awaitingColon = false
    private var currentKeyIsID = false
    private var awaitingIDValue = false
    private var isInsideString = false
    private var isEscaped = false
    private var stringRole = SimulatorWebInspectorJSONTokenRole.other
    private var token = Data()
    private var tokenOverflowed = false
    private var isCapturingScalarID = false

    /// Creates an empty extractor.
    public init() {}

    /// Consumes another piece of the JSON response.
    public mutating func ingest(_ data: Data) {
        for byte in data where requestIDToken == nil && !finished {
            ingest(byte)
        }
    }

    private mutating func ingest(_ byte: UInt8) {
        if isInsideString {
            ingestStringByte(byte)
            return
        }
        if isCapturingScalarID {
            if isWebInspectorJSONValueDelimiter(byte) {
                finishScalarID()
            } else {
                append(byte, maximumCount: maximumWebInspectorJSONIDBytes)
                return
            }
        }
        if !started {
            guard !isWebInspectorJSONWhitespace(byte) else { return }
            guard byte == 0x7B else { finished = true; return }
            started = true
            depth = 1
            expectsTopLevelKey = true
            return
        }
        if depth == 1, awaitingIDValue, !isWebInspectorJSONWhitespace(byte) {
            awaitingIDValue = false
            if byte == 0x22 {
                startString(role: .idValue)
                return
            }
            guard byte != 0x7B, byte != 0x5B else { return }
            token = Data([byte])
            tokenOverflowed = false
            isCapturingScalarID = true
            return
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

    private mutating func startString(role: SimulatorWebInspectorJSONTokenRole) {
        isInsideString = true
        isEscaped = false
        stringRole = role
        token.removeAll(keepingCapacity: true)
        tokenOverflowed = false
        if role != .other { token.append(0x22) }
    }

    private mutating func ingestStringByte(_ byte: UInt8) {
        if stringRole != .other {
            append(
                byte,
                maximumCount: stringRole == .key
                    ? maximumWebInspectorJSONKeyBytes
                    : maximumWebInspectorJSONIDBytes
            )
        }
        if isEscaped { isEscaped = false; return }
        if byte == 0x5C { isEscaped = true; return }
        guard byte == 0x22 else { return }
        isInsideString = false
        switch stringRole {
        case .key:
            currentKeyIsID = !tokenOverflowed && decodeWebInspectorJSONString(token) == "id"
            expectsTopLevelKey = false
            awaitingColon = true
        case .idValue:
            if !tokenOverflowed { requestIDToken = token }
        case .other:
            break
        }
        token.removeAll(keepingCapacity: true)
    }

    private mutating func finishScalarID() {
        if !tokenOverflowed, !token.isEmpty { requestIDToken = token }
        isCapturingScalarID = false
        token.removeAll(keepingCapacity: true)
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
}

private func decodeWebInspectorJSONString(_ token: Data) -> String? {
    var array = Data([0x5B])
    array.append(token)
    array.append(0x5D)
    return (try? JSONSerialization.jsonObject(with: array) as? [String])?.first
}

private func isWebInspectorJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

private func isWebInspectorJSONValueDelimiter(_ byte: UInt8) -> Bool {
    byte == 0x2C || byte == 0x7D || byte == 0x5D || isWebInspectorJSONWhitespace(byte)
}
