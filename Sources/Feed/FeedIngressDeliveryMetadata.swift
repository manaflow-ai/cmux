struct FeedIngressDeliveryMetadata: Sendable {
    let keys: Set<FeedIngressDeliveryKey>
    let importance: FeedIngressDeliveryImportance

    init(
        keys: Set<FeedIngressDeliveryKey>,
        importance: FeedIngressDeliveryImportance
    ) {
        precondition(!keys.isEmpty, "Feed ingress delivery requires at least one ordering key")
        self.keys = keys
        self.importance = importance
    }
}
