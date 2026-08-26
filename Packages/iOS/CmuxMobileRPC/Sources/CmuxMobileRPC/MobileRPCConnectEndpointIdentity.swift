enum MobileRPCConnectEndpointIdentity: Hashable, Sendable {
    case hostPort(kind: String, host: String, port: Int)
    case url(kind: String, endpoint: String)
}
