import Foundation

/// UTF-8 byte budgets for transcript-derived strings retained in replica entries.
struct TranscriptTextBudget: Sendable {
    static let bodyByteLimit = 16 * 1_024
    static let inputDetailByteLimit = 2 * 1_024
    static let summaryArgumentByteLimit = 80

    func body(_ text: String) -> String {
        truncated(text, byteLimit: Self.bodyByteLimit)
    }

    func inputDetail(_ text: String) -> String {
        truncated(text, byteLimit: Self.inputDetailByteLimit)
    }

    func summaryArgument(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return truncated(oneLine, byteLimit: Self.summaryArgumentByteLimit)
    }

    private func truncated(_ text: String, byteLimit: Int) -> String {
        guard text.utf8.count > byteLimit else { return text }
        let marker = "…"
        let payloadLimit = max(0, byteLimit - marker.utf8.count)
        var bytes = Array(text.utf8.prefix(payloadLimit))
        while let last = bytes.last, last & 0b1100_0000 == 0b1000_0000 {
            bytes.removeLast()
        }
        while !bytes.isEmpty, String(bytes: bytes, encoding: .utf8) == nil {
            bytes.removeLast()
        }
        return String(decoding: bytes, as: UTF8.self) + marker
    }
}
