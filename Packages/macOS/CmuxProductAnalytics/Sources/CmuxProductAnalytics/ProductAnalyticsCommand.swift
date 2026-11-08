import Foundation

/// Work queued from ``ProductAnalytics`` to its pipeline, in call order.
enum ProductAnalyticsCommand: Sendable {
    case launch
    case track(ProductAnalyticsEvent)
    case milestone(ActivationMilestone)
    case feature(ProductFeature)
    case context(ProductAnalyticsContextChange)
    case identify(userID: String)
    case signOut
    case plan(accountID: String, isPaid: Bool)
    case agentHook(source: String, sessionID: String, phase: AgentHookPhase)
    case cloudRequest(CloudRequestObservation)
    case machineCreateFinished(succeeded: Bool, errorCode: String?, seconds: Double)
    case barrier(CheckedContinuation<Void, Never>)
}
