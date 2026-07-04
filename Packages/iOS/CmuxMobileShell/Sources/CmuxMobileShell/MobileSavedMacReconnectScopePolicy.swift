/// Chooses whether a saved Mac may be dialed during reconnect from its build-scope verdict.
struct MobileSavedMacReconnectScopePolicy: Sendable {
    func isDialable(
        _ decision: MobileSavedMacScopePolicy.Decision,
        isActiveMac: Bool,
        presenceLoaded: Bool
    ) -> Bool {
        switch decision {
        case .allowed:
            return true
        case .refused:
            return false
        case .unknownIdentity:
            return isActiveMac || !presenceLoaded
        }
    }
}
