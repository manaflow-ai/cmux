import Foundation

/// Shared counters for the containers preflighting one stable snapshot value.
final class CrashEncodingBudget {
    enum Failure: Error { case exhausted, invalidValue, tooDeep }
    let maximumBytes: Int
    let maximumNodes: Int
    private(set) var usedBytes = 0
    private(set) var usedNodes = 0
    private(set) var failed = false
    var remainingBytes: Int { maximumBytes - usedBytes }

    init(maximumBytes: Int, maximumNodes: Int) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumNodes = max(0, maximumNodes)
    }

    func charge(bytes: Int, nodes: Int = 0) throws {
        guard !failed, bytes >= 0, nodes >= 0,
              bytes <= remainingBytes, nodes <= maximumNodes - usedNodes else {
            failed = true
            throw Failure.exhausted
        }
        usedBytes += bytes
        usedNodes += nodes
    }

    func checkDepth(_ depth: Int) throws {
        guard !failed, depth <= 64 else { failed = true; throw Failure.tooDeep }
    }

    /// Counts escaped JSON string bytes without materializing a UTF-8 copy.
    func string(_ value: String) throws {
        try charge(bytes: 2, nodes: 1)
        for byte in value.utf8 {
            // Slash may be escaped by Foundation; two bytes is a safe bound.
            let bytes = byte < 32 ? 6 : (byte == 34 || byte == 92 || byte == 47 ? 2 : 1)
            try charge(bytes: bytes)
        }
    }

    func fail() { failed = true }
}
