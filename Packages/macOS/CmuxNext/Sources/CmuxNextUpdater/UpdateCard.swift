import Foundation

/// The card above the footer for an update check the user asked for, or
/// what `cmux update status` reports as visible. A found, staged or
/// installing update is never a card: it is the footer's pill
/// (``UpdateFlow/footerPill(preferences:)``; Lawrence 2026-10-06).
nonisolated public enum UpdateCard: Equatable, Sendable {
    /// The user asked to check.
    case checking
    /// The user asked and a found update downloads.
    case downloading(progress: Double?)
    /// The result of a check the user asked for.
    case note(String, isError: Bool)
}
