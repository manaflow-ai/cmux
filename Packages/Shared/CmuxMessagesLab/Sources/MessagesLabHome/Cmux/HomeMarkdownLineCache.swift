/// Rendered Markdown lines outside a code fence, by their source line (HomeMarkdown.renderLine).
///
/// A line's rendering depends only on its own text, so a streaming reply's lines that did not
/// change are never parsed again (the inline parser and the bare-link scan were the largest part
/// of a token's main-thread work: plans/cmux-next/home-streaming-perf-DESIGN.md). Bounded: the
/// cache empties past `limit` lines or past its byte budget, and `HomeStreamMappers.keep` drops it
/// with its reply (p07-memory-081). Main thread only (the projection's).
final class HomeMarkdownLineCache { // memory: fixed 4096 lines, 768 KiB, one per streaming reply
    private var lines: [String: HomeMarkdown.Output] = [:]
    let limit: Int
    /// Lines rendered (misses), for tests.
    private(set) var renders = 0
    /// The estimated bytes held: each line's source and rendered text and its style runs.
    private(set) var bytes = 0
    /// The most bytes kept before the cache empties (`setBudget(bytes:)`).
    private(set) var budget = HomeMarkdownLineCache.defaultBudget
    /// A long streaming reply's distinct lines stay under 1 MB.
    static let defaultBudget = 768 << 10

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
        let size = Self.size(of: key, out)
        if lines.count >= limit || bytes + size > budget { removeAll(keepingCapacity: true) }
        guard size <= budget else { return out }
        lines[key] = out
        bytes += size
        return out
    }

    /// Lowers or raises the byte budget; frees nothing now (the next miss over it empties the cache).
    func setBudget(bytes: Int) { budget = max(0, bytes) }

    /// Frees until at most `fraction` of ``bytes`` remain. A line's rendering is cheap to make
    /// again and its order of use is not kept, so anything under 1 empties the cache.
    func trim(toFraction fraction: Double) {
        guard !fraction.isNaN, fraction < 1, bytes > bytes.trimTarget(fraction) else { return }
        removeAll(keepingCapacity: false)
    }

    /// Lines held now.
    var count: Int { lines.count }

    private func removeAll(keepingCapacity keep: Bool) {
        lines.removeAll(keepingCapacity: keep)
        bytes = 0
    }

    private static func size(of key: String, _ out: HomeMarkdown.Output) -> Int {
        key.utf8.count + out.text.utf8.count + out.runs.count * MemoryLayout<TextRun>.stride
    }
}
