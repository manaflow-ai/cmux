/// One field of ``ProductAnalyticsContext`` that changed.
public enum ProductAnalyticsContextChange: Sendable, Equatable {
    case signedIn(Bool)
    case plan(AnalyticsPlan)
    case cloudEnabled(Bool)
    case workspacesOpen(Int)
}
