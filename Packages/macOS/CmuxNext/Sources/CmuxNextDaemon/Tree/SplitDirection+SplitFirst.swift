extension SplitDirection {
    /// The side of a split made with its new tab in one daemon commit (`conversation-tab-split-v1`, which splits
    /// right or down), from an open's `direction` word; nil for left or up, or when the daemon does not serve it.
    public init?(splitFirst direction: String, served: Bool) {
        guard served else { return nil }
        switch direction {
        case "right": self = .right
        case "down": self = .down
        default: return nil
        }
    }
}
