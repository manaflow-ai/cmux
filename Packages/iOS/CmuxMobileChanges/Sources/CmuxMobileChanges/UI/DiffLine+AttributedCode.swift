#if canImport(UIKit)
internal import UIKit

extension DiffLine {
    @MainActor
    func attributedCode(font: UIFont, emphasisColor: UIColor) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
        )
        for range in emphasisRanges {
            let location = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            guard location >= 0, length >= 0, location + length <= result.length else { continue }
            result.addAttribute(
                .backgroundColor,
                value: emphasisColor,
                range: NSRange(location: location, length: length)
            )
        }
        return result
    }
}
#endif
