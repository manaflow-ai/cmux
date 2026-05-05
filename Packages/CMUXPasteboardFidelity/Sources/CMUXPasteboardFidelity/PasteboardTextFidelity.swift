import Foundation

public enum PasteboardTextFidelity {
    public static func shouldPreferPlainText(
        _ plainText: String,
        overRichText richText: String
    ) -> Bool {
        guard plainText != richText else { return false }

        let plainMetrics = textFidelityMetrics(plainText)
        let richMetrics = textFidelityMetrics(richText)

        let richTextHasLossySubstitution =
            richMetrics.replacementCharacters > plainMetrics.replacementCharacters ||
            richMetrics.questionMarks > plainMetrics.questionMarks
        let richTextSubstitutionIsRelevant =
            plainMetrics.nonASCII > 0 &&
            plainMetrics.nonASCII >= richMetrics.nonASCII

        return plainMetrics.nonASCII > richMetrics.nonASCII ||
            (richTextHasLossySubstitution && richTextSubstitutionIsRelevant)
    }

    public static func htmlHasNoVisibleText(_ html: String) -> Bool {
        var visibleCandidate = html.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: " ",
            options: .regularExpression
        )

        for hiddenBlockTag in ["script", "style", "noscript", "template"] {
            visibleCandidate = visibleCandidate.replacingOccurrences(
                of: "<\(hiddenBlockTag)\\b[^>]*>[\\s\\S]*?</\(hiddenBlockTag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        let withoutTags = visibleCandidate.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        let normalized = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&#xA0;", with: " ", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty
    }

    private static func textFidelityMetrics(
        _ text: String
    ) -> (nonASCII: Int, questionMarks: Int, replacementCharacters: Int) {
        var nonASCII = 0
        var questionMarks = 0
        var replacementCharacters = 0

        for scalar in text.unicodeScalars {
            if scalar.value == 0xFFFD {
                replacementCharacters += 1
                continue
            }
            if scalar.value > 0x7F {
                nonASCII += 1
            }
            if scalar.value == 0x3F {
                questionMarks += 1
            }
        }

        return (nonASCII, questionMarks, replacementCharacters)
    }
}
