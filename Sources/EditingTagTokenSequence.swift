import Foundation

/// Lazy, bounded tokenizer for workspace-tag edit text.
struct EditingTagTokenSequence: Sequence {
    let text: String
    let maxTokenScanLength: Int
    let maxTotalScanLength: Int

    func makeIterator() -> AnyIterator<String> {
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        let end = scalars.endIndex
        var scanned = 0
        return AnyIterator {
            // A trailing empty segment after a final delimiter is intentionally
            // not emitted because the normalizer would drop it anyway.
            guard index < end, scanned < maxTotalScanLength else { return nil }
            var token = String.UnicodeScalarView()
            var appended = 0
            while index < end, scanned < maxTotalScanLength {
                let scalar = scalars[index]
                index = scalars.index(after: index)
                scanned += 1
                if scalar == "," || scalar == "\n" {
                    return String(token)
                }
                if appended < maxTokenScanLength {
                    token.append(scalar)
                    appended += 1
                }
            }
            return String(token)
        }
    }
}
