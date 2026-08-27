enum MobileRPCConnectAdmission: Sendable, Equatable {
    case granted(MobileRPCConnectAttemptLease)
    case busy
    case cleanupBlocked
}
