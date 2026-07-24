enum FeedDeliveryTargetProbeStrategy: Equatable, Sendable {
    case process
    case surface

    init(pidNamespaceIsRemote: Bool) {
        self = pidNamespaceIsRemote ? .surface : .process
    }
}
