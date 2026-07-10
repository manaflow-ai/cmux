enum BrowserProxyConfigurationApplicationState: Equatable {
    case pristineDirect
    case explicit(identity: String)
    case directAfterExplicit(recoveryArmed: Bool)
}
