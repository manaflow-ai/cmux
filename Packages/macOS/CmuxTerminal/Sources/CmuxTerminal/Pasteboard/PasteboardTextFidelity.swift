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

    public static func shouldInspectRichTextForPlainTextLoss(_ plainText: String) -> Bool {
        let metrics = textFidelityMetrics(plainText)
        return metrics.replacementCharacters > 0 || metrics.questionMarks >= 2
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
        HTMLPlainTextParser.plainText(from: html) == nil
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
