import Foundation

/// Splits decoded artifact text into bounded main-actor presentation updates.
struct ChatArtifactTextStreamBatcher: Sendable {
    static let maximumBatchBytes = 256 * 1_024

    let maximumBatchBytes: Int

    init(maximumBatchBytes: Int = Self.maximumBatchBytes) {
        self.maximumBatchBytes = max(1, maximumBatchBytes)
    }

    func batches(for text: String) -> [String] {
        guard text.utf8.count > maximumBatchBytes else {
            return text.isEmpty ? [] : [text]
        }

        var result: [String] = []
        var start = text.startIndex
        var remainingBytes = text.utf8.count
        while start < text.endIndex {
            guard remainingBytes > maximumBatchBytes else {
                result.append(String(text[start...]))
                break
            }

            let utf8Start = start.samePosition(in: text.utf8)!
            var utf8End = text.utf8.index(utf8Start, offsetBy: maximumBatchBytes)
            while String.Index(utf8End, within: text) == nil {
                utf8End = text.utf8.index(before: utf8End)
            }
            let end = String.Index(utf8End, within: text)!
            result.append(String(text[start..<end]))
            remainingBytes -= text[start..<end].utf8.count
            start = end
        }
        return result
    }
}
