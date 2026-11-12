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

    /// Whether the plain-text flavor looks like an encoder dropped characters
    /// it could not represent, so the rich-text flavor is worth parsing.
    ///
    /// A lossy exporter (MacRoman in #2818) writes U+FFFD or one "?" per lost
    /// character, so a lost non-Latin word shows up as a run of "?". Ordinary
    /// text uses isolated "?" (questions, URL query strings), and counting
    /// those sent everyday pastes down the slow rich-text path (#9998).
    public static func shouldInspectRichTextForPlainTextLoss(_ plainText: String) -> Bool {
        var previousWasQuestionMark = false
        for scalar in plainText.unicodeScalars {
            if scalar.value == 0xFFFD { return true }
            let isQuestionMark = scalar.value == 0x3F
            if isQuestionMark && previousWasQuestionMark { return true }
            previousWasQuestionMark = isQuestionMark
        }
        return false
    }

    public static func shouldPreferRichText(
        _ richText: String,
        overPlainText plainText: String
    ) -> Bool {
        guard plainText != richText else { return false }

        let plainMetrics = textFidelityMetrics(plainText)
        let richMetrics = textFidelityMetrics(richText)

        let plainTextHasLossySubstitution =
            plainMetrics.replacementCharacters > richMetrics.replacementCharacters ||
            plainMetrics.questionMarks > richMetrics.questionMarks

        return plainTextHasLossySubstitution &&
            richMetrics.nonASCII > plainMetrics.nonASCII
    }

    public static func htmlHasNoVisibleText(_ html: String) -> Bool {
        HTMLPlainTextParser().outcome(from: html).confirmsNoVisibleText
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
