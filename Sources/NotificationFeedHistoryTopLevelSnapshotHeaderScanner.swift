import Foundation

struct NotificationFeedHistoryTopLevelSnapshotHeaderScanner: Sendable {
    var header = NotificationFeedHistorySnapshotHeader()
    private var depth = 0
    private var isInString = false
    private var isEscapingString = false
    private var isCapturingKey = false
    private var keyBytes: [UInt8] = []
    private var isExpectingKey = false
    private var isExpectingValue = false
    private var currentKey: String?
    private var numberKey: String?
    private var numberBytes: [UInt8] = []
    private var numberOverflowed = false

    mutating func consume(_ data: Data) {
        for byte in data {
            consume(byte)
            if header.isComplete { return }
        }
    }

    private mutating func consume(_ byte: UInt8) {
        if numberKey != nil {
            if consumeNumberByte(byte) {
                return
            }
            finishNumber()
            consume(byte)
            return
        }

        if isInString {
            if isEscapingString {
                isEscapingString = false
                if isCapturingKey {
                    keyBytes.append(byte)
                }
                return
            }
            if byte == Self.backslash {
                isEscapingString = true
                if isCapturingKey {
                    keyBytes.append(byte)
                }
                return
            }
            if byte == Self.quote {
                isInString = false
                if isCapturingKey {
                    currentKey = String(bytes: keyBytes, encoding: .utf8)
                    keyBytes.removeAll(keepingCapacity: true)
                    isCapturingKey = false
                }
                return
            }
            if isCapturingKey {
                keyBytes.append(byte)
            }
            return
        }

        guard !Self.isWhitespace(byte) else { return }

        switch byte {
        case Self.leftBrace, Self.leftBracket:
            if depth == 0, byte == Self.leftBrace {
                isExpectingKey = true
            }
            depth += 1
            isExpectingValue = false
        case Self.rightBrace, Self.rightBracket:
            if depth > 0 {
                depth -= 1
            }
            if depth == 1 {
                currentKey = nil
                isExpectingValue = false
            }
        case Self.comma:
            if depth == 1 {
                currentKey = nil
                isExpectingKey = true
                isExpectingValue = false
            }
        case Self.colon:
            if depth == 1, currentKey != nil {
                isExpectingKey = false
                isExpectingValue = true
            }
        case Self.quote:
            isInString = true
            if depth == 1, isExpectingKey {
                isCapturingKey = true
                keyBytes.removeAll(keepingCapacity: true)
                isExpectingKey = false
            } else {
                isCapturingKey = false
                isExpectingValue = false
            }
        default:
            guard depth == 1,
                  isExpectingValue,
                  let currentKey,
                  currentKey == "revision" || currentKey == "version",
                  (Self.isDigit(byte) || byte == Self.minus) else {
                if depth == 1, isExpectingValue {
                    isExpectingValue = false
                }
                return
            }
            startNumber(key: currentKey)
            _ = consumeNumberByte(byte)
        }
    }

    private mutating func startNumber(key: String) {
        numberKey = key
        numberBytes.removeAll(keepingCapacity: true)
        numberOverflowed = false
        isExpectingValue = false
    }

    private mutating func consumeNumberByte(_ byte: UInt8) -> Bool {
        if byte == Self.minus, numberBytes.isEmpty {
            numberBytes.append(byte)
            return true
        }
        guard Self.isDigit(byte) else { return false }
        if numberBytes.count < Self.maxIntegerLiteralByteCount {
            numberBytes.append(byte)
        } else {
            numberOverflowed = true
        }
        return true
    }

    private mutating func finishNumber() {
        guard let numberKey else { return }
        defer {
            self.numberKey = nil
            numberBytes.removeAll(keepingCapacity: true)
            numberOverflowed = false
            currentKey = nil
        }
        guard !numberOverflowed,
              let literal = String(bytes: numberBytes, encoding: .utf8),
              let value = Int(literal) else {
            return
        }
        if numberKey == "revision" {
            header.revision = value
        } else if numberKey == "version" {
            header.version = value
        }
    }

    static let backslash = UInt8(ascii: "\\")
    static let colon = UInt8(ascii: ":")
    static let comma = UInt8(ascii: ",")
    static let leftBrace = UInt8(ascii: "{")
    static let leftBracket = UInt8(ascii: "[")
    static let minus = UInt8(ascii: "-")
    static let quote = UInt8(ascii: "\"")
    static let rightBrace = UInt8(ascii: "}")
    static let rightBracket = UInt8(ascii: "]")
    private static let maxIntegerLiteralByteCount = 20

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\r")
            || byte == UInt8(ascii: "\t")
    }
}
