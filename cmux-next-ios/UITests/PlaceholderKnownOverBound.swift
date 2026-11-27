// Written by scripts/ci/ios_placeholder_bounds.py --write-known from
// cmux-next-ios/design/placeholders.json (known_over_bound, known_layout_shifts); do not edit by hand.
enum PlaceholderKnownOverBound {
    /// Placeholder id -> the item and pull request that removes it.
    static let ids: [String: String] = [
        "chat.user.empty": "item 1b (ios-optimistic-send), cmux#54993",
        "tabgrid.terminal.unavailable": "item 1a (mobile-open-fast), cmux#54985",
    ]
    /// Flow -> its layout-shift ceiling (frames; the count may only fall) and the issue that fixes it.
    static let layoutShiftFlows: [String: (maxShiftFrames: Int, issue: String)] = [:]
}
