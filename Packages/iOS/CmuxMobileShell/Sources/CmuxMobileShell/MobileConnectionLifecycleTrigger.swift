/// A fact that can require connection reconciliation.
enum MobileConnectionLifecycleTrigger: Hashable {
    case foregroundResume
    case networkPathChanged
    case presenceRoutesChanged
    case eventStreamLost
    case manualRetry
    case storedMacReconnect
}
