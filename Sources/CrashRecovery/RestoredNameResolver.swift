import Foundation

/// What name a restored window should display (U13/R16/KTD14).
nonisolated enum RestoredName: Equatable, Sendable {
    /// A user-set title was persisted — always kept, never clobbered by restore.
    case keepUserTitle(String)
    /// The window's binding verified and it had an auto-generated summary — its
    /// real summary is re-applied.
    case applyVerifiedSummary(String)
    /// No user title, and either the binding did not verify or there is no usable
    /// summary — show a neutral name. An unverified window must NOT wear another
    /// session's summary (anti-Example-1).
    case neutral
}

/// Pure rule for the name a restored window wears (U13/KTD14).
///
/// The live failure (Example 1) was a *fresh* window labeled with another
/// session's summary. The provenance machinery already round-trips
/// (`Workspace.CustomTitleSource`; `.auto` never clobbers `.user`), but on
/// restore the name must additionally be gated on *verification*: an auto
/// summary is only trustworthy for the window whose binding verified. Legacy
/// snapshots without provenance are treated as user titles, matching the
/// persistence model's backwards-compatible restore contract. This resolver
/// encodes the gate as a side-effect-free decision so it is testable without the
/// app host; the restore call site applies the result.
///
/// Order of authority:
/// 1. A user-set (`.user` or legacy nil) title is sacrosanct — kept regardless of verification.
/// 2. An auto (`.auto`) summary is re-applied ONLY when the binding verified.
/// 3. Otherwise the window shows a neutral name (never a foreign summary).
nonisolated struct RestoredNameResolver {

    func resolve(
        persistedTitle: String?,
        source: Workspace.CustomTitleSource?,
        isVerified: Bool
    ) -> RestoredName {
        let trimmed = persistedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = (trimmed?.isEmpty == false)

        // 1. A user/legacy title is never overwritten by restore.
        if hasTitle, source != .auto, let title = trimmed {
            return .keepUserTitle(title)
        }

        // 2. An auto summary is trustworthy only for a verified window.
        if hasTitle, source == .auto, isVerified, let title = trimmed {
            return .applyVerifiedSummary(title)
        }

        // 3. Unverified auto summary (or nothing usable) -> neutral name. This is
        //    the anti-Example-1 case: a fresh / mis-mapped window does not inherit
        //    a session summary it never earned.
        return .neutral
    }
}
