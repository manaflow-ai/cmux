#if DEBUG || CMUX_BENCH_HOOKS
/// The last navigation events each Chromium browser sent (DEBUG and bench builds, for
/// `debug.browser.page_status`): what changed a tab's page state, in order.
@MainActor
enum CEFEventTrace {
    private static var events: [Int32: [String]] = [:]
    private static let limit = 16
    /// Browsers kept; identifiers only grow, so the oldest go first.
    private static let browsers = 32

    static func record(_ browser: Int32, _ event: CEFShimEvent) {
        let line: String? = switch event {
        case .loadingState(_, let loading, let back, let forward): "loadingState(\(loading), back: \(back), forward: \(forward))"
        case .loadStart(_, let url, let fromPost): "loadStart(\(url)\(fromPost ? ", post" : ""))"
        case .loadEnd(_, let status): "loadEnd(\(status))"
        case .loadError(_, let code, _, let url, let interstitial): "loadError(\(code), \(url), interstitial: \(interstitial))"
        case .address(_, let url): "address(\(url))"
        default: nil
        }
        guard let line else { return }
        if events[browser] == nil, events.count >= browsers, let oldest = events.keys.min() { events[oldest] = nil }
        events[browser, default: []].append(line)
        if let count = events[browser]?.count, count > limit { events[browser]?.removeFirst(count - limit) }
    }

    static func recent(_ browser: Int32?) -> [String] {
        browser.flatMap { events[$0] } ?? []
    }
}
#endif
