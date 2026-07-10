enum RPCStackTokenScopeKey: Hashable, Sendable {
    case unscoped
    case scoped(MobileRPCAuthScope)
}
