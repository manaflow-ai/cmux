enum MobileRPCConnectEndpointIdentity: Hashable, Sendable {
    case iroh(endpointID: String)
    case hostPort(kind: String, host: String, port: Int)
    case url(kind: String, endpoint: String)
}
