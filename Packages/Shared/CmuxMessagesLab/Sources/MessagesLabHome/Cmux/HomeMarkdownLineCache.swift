/// Rendered Markdown lines outside a code fence, by their source line (HomeMarkdown.renderLine).
///
/// A line's rendering depends only on its own text, so a streaming reply's lines that did not
/// change are never parsed again (the inline parser and the bare-link scan were the largest part
/// of a token's main-thread work: plans/cmux-next/home-streaming-perf-DESIGN.md). Bounded: the
/// cache empties past `limit` lines. Main thread only (the projection's).
final class HomeMarkdownLineCache {
    private var lines: [String: HomeMarkdown.Output] = [:]
    let limit: Int
    /// Lines rendered (misses), for tests.
    private(set) var renders = 0

    /// Chip links show as chips (`HomeMarkdown.render(_:chips:)`; the transcript's rendering: `HomeLinkChip.showsInTranscript`).
    let chips: Bool

    init(limit: Int = 4096, chips: Bool = HomeLinkChip.showsInTranscript) { self.limit = limit; self.chips = chips }

    func rendered(_ raw: Substring) -> HomeMarkdown.Output {
        let key = String(raw)
        if let hit = lines[key] { return hit }
        var out = HomeMarkdown.Output()
        out.chips = chips
        HomeMarkdown.renderLine(key, into: &out)
        renders += 1
        if lines.count >= limit { lines.removeAll(keepingCapacity: true) }
        lines[key] = out
        return out
    }
}
