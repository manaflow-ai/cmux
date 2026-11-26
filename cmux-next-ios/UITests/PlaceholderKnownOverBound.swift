// Written by scripts/ci/ios_placeholder_bounds.py --write-known from
// cmux-next-ios/design/placeholders.json (known_over_bound); do not edit by hand.
enum PlaceholderKnownOverBound {
    /// Placeholder id -> the item and pull request that removes it.
    static let ids: [String: String] = [
        "chat.user.empty": "item 1b (ios-optimistic-send), cmux#54993",
        "tabgrid.terminal.unavailable": "item 1a (mobile-open-fast), cmux#54985",
    ]
    /// Flow -> the item and pull request that brings its layout-shift count to zero.
    static let layoutShiftFlows: [String: String] = [:]
}
