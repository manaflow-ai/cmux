import Foundation

/// The terminal operation being traced. Values are stable on the wire.
public enum DiagnosticTerminalTraceOperation: Int, Sendable, Codable, CaseIterable {
    case replay = 1
    case artifactScan = 2
    case artifactList = 3
}

/// A phase in one terminal operation.
public enum DiagnosticTerminalTracePhase: Int, Sendable, Codable, CaseIterable {
    case started = 1
    case requestSent = 2
    case hostReceived = 3
    case hostCaptureFinished = 4
    case responseReceived = 5
    case decoded = 6
    case applied = 7
    case failed = 8
    case discarded = 9
}

/// A short opaque ID that can safely cross the mobile RPC boundary.
public struct DiagnosticTerminalTraceID: Sendable, Codable, Equatable, Hashable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue == 0 ? 1 : rawValue
    }

    public init() {
        self.init(rawValue: UInt64.random(in: 1...UInt64.max))
    }

    /// Fixed-width lowercase hex keeps log searches unambiguous and bounded.
    public var stringValue: String {
        let value = String(rawValue, radix: 16, uppercase: false)
        return String(repeating: "0", count: max(0, 16 - value.count)) + value
    }

    public init?(stringValue: String) {
        guard stringValue.count == 16,
              stringValue.unicodeScalars.allSatisfy({
                  ($0.value >= 48 && $0.value <= 57)
                      || ($0.value >= 97 && $0.value <= 102)
              }),
              let value = UInt64(stringValue, radix: 16),
              value != 0 else {
            return nil
        }
        rawValue = value
    }
}
