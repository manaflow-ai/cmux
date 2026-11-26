enum FeedIngressDeliveryImportance: Sendable, Equatable {
    case ordinary
    case sessionCritical
    case acknowledged

    var isPriority: Bool {
        self != .ordinary
    }
}
