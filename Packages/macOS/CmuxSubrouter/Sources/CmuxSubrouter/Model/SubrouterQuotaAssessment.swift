/// Whether an account's quota windows still allow work, mirroring the `sr`
/// CLI's `cookedFromWindows` / `tempCookedFromWindows` derivation exactly.
///
/// - ``cooked(_:)``: a long (weekly) window is fully consumed — the account
///   is unusable until the weekly reset.
/// - ``tempCooked(_:)``: no long window is saturated, but a short (~5h
///   session) window is fully consumed — a new session cannot start until
///   the short window resets.
/// - ``ok``: neither condition holds.
public enum SubrouterQuotaAssessment: Sendable, Hashable {
    /// No saturated quota window.
    case ok
    /// A short (session) window is fully consumed; recovers at its reset.
    case tempCooked(SubrouterUsageWindow)
    /// A long (weekly) window is fully consumed; unusable until its reset.
    case cooked(SubrouterUsageWindow)

    /// Derives the assessment from a set of usage windows.
    ///
    /// Mirrors `sr.go`: the first **provider-wide** long window at 100%
    /// (clamped) wins as ``cooked(_:)`` — a model-scoped (feature) window's
    /// saturation never cooks the whole account, exactly like
    /// `isModelScopedWindow` in `cookedFromWindows`; otherwise the first
    /// short window at 100% wins as ``tempCooked(_:)`` (the daemon applies
    /// no model-scope filter there); otherwise ``ok``. Window order is
    /// preserved as reported by the daemon.
    ///
    /// - Parameter windows: The account's usage windows.
    /// - Returns: The derived assessment.
    public static func assess(_ windows: [SubrouterUsageWindow]) -> SubrouterQuotaAssessment {
        if let saturatedLong = windows.first(where: {
            !$0.isModelScoped && $0.isLongQuotaWindow && $0.isFullyConsumed
        }) {
            return .cooked(saturatedLong)
        }
        if let saturatedShort = windows.first(where: { $0.isShortQuotaWindow && $0.isFullyConsumed }) {
            return .tempCooked(saturatedShort)
        }
        return .ok
    }
}
