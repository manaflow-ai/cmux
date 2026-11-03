/// `home.feedInChief` in cmux.json: the main Chief's conversation shows the Feed's notices (updates,
/// pull requests) as read-only lines among its messages (`HomeFeedRow`). They are the person's only:
/// the Chief never reads them. On by default; off opts out (Leo 2026-10-20: "we don't necessarily
/// want to bother the chief with lots of TMI type information, but we want to make it like easily
/// accessible ... you can opt out if you want").
public nonisolated struct HomeFeedRowsSetting {
    public nonisolated init() {}
    public static let configPath = ["home", "feedInChief"]
    public static let key = configPath.joined(separator: ".")
}
