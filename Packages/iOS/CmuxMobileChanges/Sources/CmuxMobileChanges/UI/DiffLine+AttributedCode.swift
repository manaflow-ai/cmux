import SwiftUI

extension DiffLine {
    func attributedCode(emphasisColor: Color) -> AttributedString {
        guard !emphasisRanges.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        for range in emphasisRanges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard cursor <= range.lowerBound, range.upperBound <= text.endIndex else { continue }
            result.append(AttributedString(String(text[cursor..<range.lowerBound])))
            var emphasized = AttributedString(String(text[range]))
            emphasized.backgroundColor = emphasisColor
            result.append(emphasized)
            cursor = range.upperBound
        }
        result.append(AttributedString(String(text[cursor...])))
        return result
    }
}
