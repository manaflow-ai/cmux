/// Rendered Markdown lines outside a code fence, by their source line (HomeMarkdown.renderLine).
///
/// A line's rendering depends only on its own text, so a streaming reply's lines that did not
/// change are never parsed again (the inline parser and the bare-link scan were the largest part
/// of a token's main-thread work: plans/cmux-next/home-streaming-perf-DESIGN.md). Bounded: the
/// cache empties past `limit` lines or past `budget` bytes, and `HomeStreamMappers.keep` drops it
/// with its reply. It is not in the host's memory consumer: it lives only while its
/// reply streams on screen, so its fixed cap is the whole bound. Main thread only (the projection's).
final class HomeMarkdownLineCache { // memory: fixed 4096 lines, 768 KiB, one per streaming reply
    private var lines: [String: HomeMarkdown.Output] = [:]
    let limit: Int
    /// Lines rendered (misses), for tests.
    private(set) var renders = 0
    /// The estimated bytes held: each line's source and rendered text and its style runs.
    private(set) var bytes = 0
    /// The most bytes kept before the cache empties: a long streaming reply's distinct lines stay under 1 MB.
    let budget: Int
    static let defaultBudget = 768 << 10

    /// Chip links show as chips (`HomeMarkdown.render(_:chips:)`; the transcript's rendering: `HomeLinkChip.showsInTranscript`).
    let chips: Bool

    init(limit: Int = 4096, budget: Int = HomeMarkdownLineCache.defaultBudget, chips: Bool = HomeLinkChip.showsInTranscript) {
        self.limit = limit
        self.budget = max(0, budget)
        self.chips = chips
    }

    func rendered(_ raw: Substring) -> HomeMarkdown.Output {
        let key = String(raw)
        if let hit = lines[key] { return hit }
        var out = HomeMarkdown.Output()
        out.chips = chips
        HomeMarkdown.renderLine(key, into: &out)
        renders += 1
        let size = Self.size(of: key, out)
        if lines.count >= limit || bytes + size > budget { empty() }
        guard size <= budget else { return out }
        lines[key] = out
        bytes += size
        return out
    }

    /// Lines held now.
    var count: Int { lines.count }

    private func empty() {
        lines.removeAll(keepingCapacity: true)
        bytes = 0
    }

    private static func size(of key: String, _ out: HomeMarkdown.Output) -> Int {
        key.utf8.count + out.text.utf8.count + out.runs.count * MemoryLayout<TextRun>.stride
    }
}
