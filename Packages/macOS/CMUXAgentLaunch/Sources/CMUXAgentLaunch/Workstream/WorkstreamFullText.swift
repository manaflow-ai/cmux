import Foundation

extension WorkstreamItem {
    /// Content for reading, independent of the bounded timeline preview.
    public var fullText: String {
        switch payload {
        case .stop(let reason):
            return reason ?? context?.assistantPreamble ?? ""
        case .assistantMessage(let text), .userPrompt(let text):
            return text
        case .exitPlan(_, let plan, _):
            return WorkstreamExitPlanPreview(rawPlan: plan).planText
        case .question(_, let questions):
            return questions.map { question in
                [question.header, question.prompt].compactMap { $0 }.joined(separator: "\n")
            }.joined(separator: "\n\n")
        case .permissionRequest:
            return context?.assistantPreamble ?? ""
        case .toolResult(_, let result, _):
            return result
        case .toolUse(_, let input):
            return input
        case .todos, .sessionStart, .sessionEnd:
            return ""
        }
    }
}

/// UTF-8 pages keep a single long message below the mobile frame limit.
/// Offsets refer to bytes; boundaries never split a Unicode scalar.
public struct WorkstreamTextPage: Sendable {
    public let text: String
    public let nextOffset: Int?

    public init?(text: String, offset: Int) {
        let bytes = text.utf8
        guard offset >= 0, offset <= bytes.count else { return nil }
        let start = bytes.index(bytes.startIndex, offsetBy: offset)
        guard start == bytes.endIndex || bytes[start] & 0xC0 != 0x80 else { return nil }
        var end = bytes.index(start, offsetBy: 16_384, limitedBy: bytes.endIndex) ?? bytes.endIndex
        while end != bytes.endIndex, bytes[end] & 0xC0 == 0x80 {
            end = bytes.index(before: end)
        }
        guard let page = String(bytes: bytes[start..<end], encoding: .utf8) else { return nil }
        self.text = page
        nextOffset = end == bytes.endIndex ? nil : offset + page.utf8.count
    }
}
