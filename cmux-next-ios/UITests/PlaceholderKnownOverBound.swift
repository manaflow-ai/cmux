// Written by scripts/ci/ios_placeholder_bounds.py --write-known from
// cmux-next-ios/design/placeholders.json (known_over_bound); do not edit by hand.
enum PlaceholderKnownOverBound {
    /// Placeholder id -> the item and pull request that removes it.
    static let ids: [String: String] = [
        "chat.user.empty": "item 1b (ios-optimistic-send), cmux#54993",
        "cloud.chat.connecting": "item 3 (conn-chip-ios-surfaces), cmux#54994",
        "feed.connecting": "item 3 (conn-chip-ios-surfaces), cmux#54994",
        "tabgrid.browser.globe": "item 1a (mobile-open-fast), cmux#54985",
        "tabgrid.stream.icon": "item 1a (mobile-open-fast), cmux#54985",
        "tabgrid.terminal.connecting": "item 1a (mobile-open-fast), cmux#54985",
        "tabgrid.terminal.placeholder": "item 1a (mobile-open-fast), cmux#54985",
        "tabgrid.terminal.unavailable": "item 1a (mobile-open-fast), cmux#54985",
    ]
}
