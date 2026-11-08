import Foundation

/// Distinguishes visible HTML text, confirmed absence, and bounded rejection.
enum HTMLPlainTextParseOutcome: Equatable, Sendable {
    case visibleText(String)
    case noVisibleText
    case rejected

    var plainText: String? {
        guard case .visibleText(let text) = self else { return nil }
        guard !text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return nil
        }
        return text
    }

    var confirmsNoVisibleText: Bool {
        switch self {
        case .visibleText(let text):
            return text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        case .noVisibleText:
            return true
        case .rejected:
            return false
        }
    }
}
