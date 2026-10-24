/// The account's plan as the app knows it.
public enum AnalyticsPlan: String, Sendable, CaseIterable {
    case free
    case paid
    /// Signed out, or the plan has not loaded.
    case unknown
}
