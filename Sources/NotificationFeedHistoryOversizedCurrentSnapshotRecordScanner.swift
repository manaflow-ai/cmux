import Foundation

struct NotificationFeedHistoryOversizedCurrentSnapshotRecordScanner: Sendable {
    let maxRecordBytes: Int
    private var depth = 0
    private var isInString = false
    private var isEscapingString = false
    private var isCapturingKey = false
    private var keyOverflowed = false
    private var keyBytes: [UInt8] = []
    private var isExpectingKey = false
    private var isExpectingValue = false
    private var currentKey: String?
    private var didStartNotificationsArray = false
    private var didFinishNotificationsArray = false
    private var recordObjectDepth = 0
    private var recordBytes = Data()
    private var recordOverflowed = false
    private var recordIsInString = false
    private var recordIsEscapingString = false

    private static let maxTopLevelKeyByteCount = 128

    init(maxRecordBytes: Int) {
        self.maxRecordBytes = max(0, maxRecordBytes)
    }

    var topLevelKeyBufferByteCountForTesting: Int {
        keyBytes.count
    }

    mutating func consume(
        _ data: Data,
        onRecord: (Data) throws -> Bool
    ) rethrows -> Bool {
        guard !didFinishNotificationsArray else { return false }
        for byte in data {
            let shouldContinue: Bool
            if didStartNotificationsArray {
                shouldContinue = try consumeNotificationsArrayByte(
                    byte,
                    onRecord: onRecord
                )
            } else {
                shouldContinue = consumeTopLevelByte(byte)
            }
            guard shouldContinue else { return false }
        }
        return true
    }

    private mutating func consumeTopLevelByte(_ byte: UInt8) -> Bool {
        if isInString {
            if isEscapingString {
                isEscapingString = false
                if isCapturingKey {
                    appendKeyByte(byte)
                }
                return true
            }
            if byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.backslash {
                isEscapingString = true
                if isCapturingKey {
                    appendKeyByte(byte)
                }
                return true
            }
            if byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.quote {
                isInString = false
                if isCapturingKey, !keyOverflowed {
                    currentKey = String(bytes: keyBytes, encoding: .utf8)
                    keyBytes.removeAll(keepingCapacity: true)
                    isCapturingKey = false
                } else if isCapturingKey {
                    currentKey = nil
                    keyBytes.removeAll(keepingCapacity: false)
                    isCapturingKey = false
                    keyOverflowed = false
                }
                return true
            }
            if isCapturingKey {
                appendKeyByte(byte)
            }
            return true
        }

        guard !NotificationFeedHistoryTopLevelSnapshotHeaderScanner.isWhitespace(byte) else {
            return true
        }

        switch byte {
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.leftBrace:
            if depth == 0 {
                isExpectingKey = true
            }
            depth += 1
            isExpectingValue = false
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.rightBrace,
             NotificationFeedHistoryTopLevelSnapshotHeaderScanner.rightBracket:
            if depth > 0 {
                depth -= 1
            }
            if depth == 1 {
                currentKey = nil
                isExpectingValue = false
            }
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.leftBracket:
            if depth == 1,
               isExpectingValue,
               currentKey == "notifications" {
                didStartNotificationsArray = true
                currentKey = nil
                isExpectingValue = false
                isExpectingKey = false
                return true
            }
            depth += 1
            isExpectingValue = false
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.comma:
            if depth == 1 {
                currentKey = nil
                isExpectingKey = true
                isExpectingValue = false
            }
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.colon:
            if depth == 1, currentKey != nil {
                isExpectingKey = false
                isExpectingValue = true
            }
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.quote:
            isInString = true
            if depth == 1, isExpectingKey {
                isCapturingKey = true
                keyOverflowed = false
                keyBytes.removeAll(keepingCapacity: true)
                isExpectingKey = false
            } else {
                isCapturingKey = false
                keyOverflowed = false
                isExpectingValue = false
            }
        default:
            if depth == 1, isExpectingValue {
                isExpectingValue = false
            }
        }
        return true
    }

    private mutating func appendKeyByte(_ byte: UInt8) {
        guard !keyOverflowed else { return }
        guard keyBytes.count < Self.maxTopLevelKeyByteCount else {
            keyOverflowed = true
            keyBytes.removeAll(keepingCapacity: false)
            return
        }
        keyBytes.append(byte)
    }

    private mutating func consumeNotificationsArrayByte(
        _ byte: UInt8,
        onRecord: (Data) throws -> Bool
    ) rethrows -> Bool {
        guard recordObjectDepth == 0 else {
            return try consumeRecordByte(byte, onRecord: onRecord)
        }

        if NotificationFeedHistoryTopLevelSnapshotHeaderScanner.isWhitespace(byte)
            || byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.comma {
            return true
        }
        if byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.rightBracket {
            didFinishNotificationsArray = true
            return false
        }
        guard byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.leftBrace else {
            return true
        }
        return try consumeRecordByte(byte, onRecord: onRecord)
    }

    private mutating func consumeRecordByte(
        _ byte: UInt8,
        onRecord: (Data) throws -> Bool
    ) rethrows -> Bool {
        appendRecordByte(byte)

        if recordIsInString {
            if recordIsEscapingString {
                recordIsEscapingString = false
                return true
            }
            if byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.backslash {
                recordIsEscapingString = true
                return true
            }
            if byte == NotificationFeedHistoryTopLevelSnapshotHeaderScanner.quote {
                recordIsInString = false
            }
            return true
        }

        switch byte {
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.quote:
            recordIsInString = true
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.leftBrace:
            recordObjectDepth += 1
        case NotificationFeedHistoryTopLevelSnapshotHeaderScanner.rightBrace:
            recordObjectDepth -= 1
            guard recordObjectDepth == 0 else { return true }
            defer { resetRecord() }
            guard !recordOverflowed else { return true }
            return try onRecord(recordBytes)
        default:
            break
        }
        return true
    }

    private mutating func appendRecordByte(_ byte: UInt8) {
        guard !recordOverflowed else { return }
        guard recordBytes.count < maxRecordBytes else {
            recordOverflowed = true
            recordBytes.removeAll(keepingCapacity: false)
            return
        }
        recordBytes.append(byte)
    }

    private mutating func resetRecord() {
        recordObjectDepth = 0
        recordBytes.removeAll(keepingCapacity: true)
        recordOverflowed = false
        recordIsInString = false
        recordIsEscapingString = false
    }
}
