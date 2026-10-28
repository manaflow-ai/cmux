import CMUXAgentLaunch
import Foundation

/// Tunables for the automatic task-difficulty assessment that runs at the end
/// of a Claude turn.
struct DifficultyAssessmentConfig {
    /// Minimum seconds between two assessments of the same session.
    static let minInterval: TimeInterval = 180
    /// An in-flight marker older than this is treated as a crashed pass.
    static let inFlightExpiry: TimeInterval = 75
    /// Maximum characters kept from each of the user and assistant excerpts.
    static let excerptLimit = 1_500
    /// Seconds to wait for the `claude -p` classification call.
    static let llmTimeout: TimeInterval = 60
    /// Store entries untouched for this long are dropped on the next write.
    static let storeRetention: TimeInterval = 24 * 60 * 60
}

/// Outcome of the per-session difficulty throttle.
enum DifficultyAssessmentDecision: Equatable, Sendable {
    case proceed
    case skipInFlight
    case skipTooSoon
}

/// Pure pieces of the difficulty assessment: prompt, response parsing,
/// excerpt selection and the throttle decision.
enum DifficultyAssessmentEngine {
    static func buildPrompt(lastUserMessage: String, lastAssistantMessage: String) -> String {
        let user = String(lastUserMessage.prefix(DifficultyAssessmentConfig.excerptLimit))
        let assistant = String(lastAssistantMessage.prefix(DifficultyAssessmentConfig.excerptLimit))
        return [
            "Classify how demanding the current coding task is.",
            "Reply with exactly one word: easy, normal, or hard. No other text.",
            "",
            "easy: small, local, well-specified change (a rename, a typo, a one-file tweak).",
            "normal: a typical feature or fix that touches a few places with a clear approach.",
            "hard: multi-file design, debugging unknown causes, or open-ended research.",
            "",
            "Latest user message:",
            user,
            "",
            "Latest assistant message:",
            assistant,
        ].joined(separator: "\n")
    }

    /// Accepts only a single word naming a difficulty, ignoring case,
    /// surrounding whitespace, quotes and punctuation. Sentences are rejected.
    static func parse(_ response: String) -> ClaudeSessionDifficulty? {
        guard let firstLine = response
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) else {
            return nil
        }
        let word = firstLine
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces))
            .lowercased()
        return ClaudeSessionDifficulty(rawValue: word)
    }

    /// The most recent user and assistant messages, or `nil` when either is missing.
    static func excerpt(from messages: [AutoNamingTranscriptMessage]) -> (user: String, assistant: String)? {
        guard let user = messages.last(where: { $0.role == "user" }),
              let assistant = messages.last(where: { $0.role == "assistant" }) else {
            return nil
        }
        return (user.text, assistant.text)
    }

    static func throttleDecision(
        inFlightAt: TimeInterval?,
        lastAssessedAt: TimeInterval?,
        now: Date
    ) -> DifficultyAssessmentDecision {
        let t = now.timeIntervalSince1970
        if let inFlightAt, t - inFlightAt < DifficultyAssessmentConfig.inFlightExpiry {
            return .skipInFlight
        }
        if let lastAssessedAt, t - lastAssessedAt < DifficultyAssessmentConfig.minInterval {
            return .skipTooSoon
        }
        return .proceed
    }
}
