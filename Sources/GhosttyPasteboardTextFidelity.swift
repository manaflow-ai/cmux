extension GhosttyPasteboardHelper {
    static func shouldPreferPlainText(
        _ plainText: String,
        overRichText richText: String
    ) -> Bool {
        guard plainText != richText else { return false }

        let plainMetrics = textFidelityMetrics(plainText)
        let richMetrics = textFidelityMetrics(richText)

        let richTextHasLossySubstitution =
            richMetrics.replacementCharacters > plainMetrics.replacementCharacters ||
            richMetrics.questionMarks > plainMetrics.questionMarks
        let plainTextPreservesAtLeastAsMuchNonASCII = plainMetrics.nonASCII >= richMetrics.nonASCII

        return plainMetrics.nonASCII > richMetrics.nonASCII ||
            (richTextHasLossySubstitution && plainTextPreservesAtLeastAsMuchNonASCII)
    }

    private static func textFidelityMetrics(
        _ text: String
    ) -> (nonASCII: Int, questionMarks: Int, replacementCharacters: Int) {
        var nonASCII = 0
        var questionMarks = 0
        var replacementCharacters = 0

        for scalar in text.unicodeScalars {
            if scalar.value > 0x7F {
                nonASCII += 1
            }
            if scalar.value == 0x3F {
                questionMarks += 1
            }
            if scalar.value == 0xFFFD {
                replacementCharacters += 1
            }
        }

        return (nonASCII, questionMarks, replacementCharacters)
    }

    static func htmlHasNoVisibleText(_ html: String) -> Bool {
        let withoutComments = html.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutComments.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
    }
}
