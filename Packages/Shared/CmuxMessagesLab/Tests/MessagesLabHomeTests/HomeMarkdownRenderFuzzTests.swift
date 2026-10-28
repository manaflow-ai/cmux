import AppKit
import CmuxFuzzSupport
import Foundation
import Testing
@testable import MessagesLabHome

/// Seeded fuzz of the Mac Home transcript's text render (plans/cmux-next/chrome-parity/p10-stability.md, task 028):
/// hostile Markdown (`FuzzText`: open and closed fences, ragged tables, delimiter runs, ZWJ emoji, combining
/// marks, CRLF and lone CR, huge lines) through the short path (`MarkdownStore` parse, `MarkdownLayoutEngine`,
/// `MarkdownDraw`) and the long path (`LongTextStore`, `LongTextLayout`, `TiledBubble` tiles, Markdown tiles),
/// streamed a few scalars at a time and edited between a measurement and its draw: the layout measured for
/// one token is drawn and hit-tested with positions of the next text, as a row is until its new layout lands.
/// Chrome fuzzes the same layers (third_party/blink/renderer/platform/fonts/shaping/harfbuzz_shaper_fuzzer.cc,
/// third_party/blink/renderer/core/layout/ng/inline/ fuzzers) and bounds each input with libFuzzer's timeout
/// (testing/libfuzzer/README.md); here the bound is the Home budget.
///
/// Properties: no trap (a trap ends the run, so a finished run is the proof); a streamed document has the
/// blocks a fresh parse of the same text has; every layout is finite and its offsets stay in its text; a long
/// text's index covers its own text, byte for byte, in blocks cut at character boundaries; a 64 KiB render
/// (index, measure, the tiles of the first and the last screen) takes under 50 ms in an optimized build.
///
/// It runs only with `CMUX_HOME_RENDER_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_HOME_RENDER_FUZZ=1 swift test -c release -Xswiftc -enable-testing --filter HomeMarkdownRenderFuzzTests
/// CMUX_HOME_RENDER_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test -c release -Xswiftc -enable-testing --filter HomeMarkdownRenderFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s: `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure, and
/// with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its case behind. The suite is serialized, so each of its
/// ``runCount`` runs gets an equal share of `CMUX_FUZZ_DEADLINE`.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_HOME_RENDER_FUZZ"] == "1",
        "set CMUX_HOME_RENDER_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct HomeMarkdownRenderFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs that share a `CMUX_FUZZ_DEADLINE`.
    static let runCount = 6

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    /// A run of this suite: the process's `CMUX_FUZZ_*` variables, its long mode capped at ``deadlineShare``.
    static func run(_ name: String, seed: UInt64, iterations: Int) throws -> FuzzRun {
        var environment = try FuzzEnvironment.current()
        if let share = deadlineShare { environment.seconds = min(environment.seconds ?? share, share) }
        return FuzzRun(name, seed: seed, iterations: iterations, environment: environment)
    }

    /// The budget is a property of an optimized build; a Debug build's unoptimized Swift would fail it.
    nonisolated static let optimized: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Short texts (Home lays out up to 8 KiB as one Markdown layout) and long ones (tiles).
    static let short = FuzzText(maxBytes: 8 << 10)
    static let long = FuzzText(maxBytes: 48 << 10)
    static let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: 64 << 10)
    static let columns: [CGFloat] = [1, 40, 200, 358.4, 620, 2_000]
    /// Pane widths of the long path (a 1 pt column would make every character a line: minutes per input).
    static let paneWidths: [CGFloat] = [120, 400, 760, 1_400]

    /// Lineages no `LongTextStore` hands out, so a directly built index never meets another text's cached blocks.
    static var lineageSerial = 1 << 40
    static func nextLineage() -> Int {
        lineageSerial += 1
        return lineageSerial
    }

    // MARK: - Short path

    static func layout(_ text: String, width: CGFloat) -> MarkdownLayout {
        MarkdownLayoutEngine.layout(MarkdownStore.shared.document(text), source: text, maxWidth: width)
    }

    /// A finite layout whose fragments, boxes and regions sit inside it and whose ranges index its display string.
    static func check(_ md: MarkdownLayout) throws {
        let size = md.size
        try FuzzRun.check(size.width.isFinite && size.height.isFinite && size.width >= 0 && size.height >= 0, "layout size \(size)")
        for (i, f) in md.frags.enumerated() {
            try FuzzRun.check(f.origin.x.isFinite && f.origin.y.isFinite && f.width.isFinite, "fragment \(i) at \(f.origin), \(f.width) wide")
            try FuzzRun.check(f.range.location >= 0 && f.range.length >= 0 && f.range.location <= md.length - f.range.length,
                              "fragment \(i) \(f.range) is outside \(md.length) units")
        }
        for (i, box) in md.boxes.enumerated() {
            let r = box.rect
            try FuzzRun.check(r.origin.x.isFinite && r.origin.y.isFinite && r.width.isFinite && r.height.isFinite, "box \(i) is \(r)")
        }
        for (i, region) in md.regions.enumerated() {
            try FuzzRun.check(region.frame.width.isFinite && region.frame.height.isFinite && region.contentWidth.isFinite,
                              "region \(i) is \(region.frame), \(region.contentWidth) of content")
        }
    }

    /// A viewport-sized bitmap context, flipped to top-left points as the row bitmaps are.
    static func context() -> CGContext? {
        let ctx = CGContext.ownedBitmap(width: 480, height: 640, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.translateBy(x: 0, y: 640)
        ctx?.scaleBy(x: 1, y: -1)
        return ctx
    }

    /// Draws the whole layout, each region alone (the overlay bitmaps), the body without its scrollable
    /// regions, and a region of another layout (which draws nothing).
    static func draw(_ md: MarkdownLayout, outgoing: Bool) {
        guard let ctx = context() else { return }
        let body = CGRect(origin: .zero, size: md.size)
        MarkdownDraw.draw(ctx, md, body: body, outgoing: outgoing)
        MarkdownDraw.draw(ctx, md, body: body, outgoing: outgoing, mode: .skipScrollable)
        for i in md.regions.indices { MarkdownDraw.draw(ctx, md, body: body, outgoing: outgoing, mode: .region(i)) }
        MarkdownDraw.draw(ctx, md, body: body, outgoing: outgoing, mode: .region(md.regions.count + 1))
    }

    /// Hit tests, selection and copy with positions of a text `staleLength` units long: the layout's own
    /// text, or the next one when the layout is still on screen after an edit.
    static func probe(_ md: MarkdownLayout, staleLength: Int, _ rng: inout FuzzRNG) throws {
        let n = max(0, staleLength)
        let height = Double(md.size.height)
        for _ in 0..<6 {
            let p = CGPoint(x: rng.double(in: -50...900), y: rng.double(in: -50...(height + 50)))
            let o = md.offset(at: p)
            try FuzzRun.check(o >= 0 && o <= md.length, "offset \(o) at \(p) is outside \(md.length) units")
            _ = md.link(at: p)
            _ = md.region(at: p)
        }
        for _ in 0..<4 {
            let a = rng.int(in: 0...n)
            let r = NSRange(location: a, length: rng.int(in: 0...(n - a)))
            _ = md.substring(r)
            _ = md.selectionRects(r, visible: -1e6...1e6)
            let o = rng.int(in: 0...n)
            _ = md.wordRange(at: o)
            _ = md.paragraphRange(at: o)
        }
    }

    static func markdownStep(_ rng: inout FuzzRNG) throws {
        let source = short.text(&rng)
        let md = layout(source, width: columns[rng.below(columns.count)])
        try check(md)
        draw(md, outgoing: rng.bool())
        try probe(md, staleLength: md.length, &rng)
    }

    @Test(.timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes)))
    func hostileMarkdownLaysOutAndDraws() throws {
        try Self.run("HomeMarkdown.short", seed: 0x3D_1A70, iterations: 200).forEach { rng in
            try Self.markdownStep(&rng)
        }
    }

    /// A reply streamed at scalar cuts (ZWJ sequences, CRLF pairs and fence markers split), sometimes edited:
    /// each token's text parses to the blocks a fresh parse gives, and the previous token's layout is drawn
    /// and hit-tested with the new text's positions before the new layout replaces it.
    static func streamStep(_ rng: inout FuzzRNG) throws {
        let whole = short.text(&rng)
        let width = columns[rng.below(columns.count)]
        var previous: MarkdownLayout?
        for prefix in FuzzText.stream(whole, steps: 1 + rng.below(10), &rng) {
            let text = rng.oneIn(4) ? short.edit(prefix, &rng) : prefix
            let streamed = MarkdownStore.shared.document(text)
            let fresh = Markdown.parse(text)
            try FuzzRun.check(streamed.blocks.map(\.kind) == fresh.blocks.map(\.kind)
                              && streamed.blocks.map(\.blankBefore) == fresh.blocks.map(\.blankBefore),
                              "a streamed parse of \(text.utf8.count) bytes has \(streamed.blocks.count) blocks, a fresh one \(fresh.blocks.count)")
            if let previous {
                draw(previous, outgoing: false)
                try probe(previous, staleLength: (text as NSString).length, &rng)
            }
            let md = MarkdownLayoutEngine.layout(streamed, source: text, maxWidth: width)
            try check(md)
            draw(md, outgoing: false)
            previous = md
        }
    }

    @Test(.timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes)))
    func aStreamEditedBetweenMeasureAndDrawParsesAsAFreshText() throws {
        try Self.run("HomeMarkdown.stream", seed: 0x57_2EA4, iterations: 120).forEach { rng in
            try Self.streamStep(&rng)
        }
    }

    // MARK: - Long path

    /// The layout's index covers `text` byte for byte, in blocks cut at character boundaries, with its
    /// UTF-16 length; its height and every block's line count are usable.
    static func check(_ l: LongTextLayout, of text: String) throws {
        let idx = l.index
        try FuzzRun.check(idx.text.utf8.elementsEqual(text.utf8),
                          "the layout of \(text.utf8.count) bytes holds another text (\(idx.count) bytes, lineage \(idx.lineage))")
        let bytes = Array(text.utf8)
        try FuzzRun.check(idx.starts.first == 0 && idx.starts.last == bytes.count,
                          "blocks span \(String(describing: idx.starts.first)) to \(String(describing: idx.starts.last)) of \(bytes.count) bytes")
        for (a, b) in zip(idx.starts, idx.starts.dropFirst()) {
            try FuzzRun.check(a < b, "block starts \(a) then \(b)")
            try FuzzRun.check(bytes[a] & 0xC0 != 0x80, "a block starts inside a character at byte \(a)")
        }
        let units = (text as NSString).length
        try FuzzRun.check(idx.u16Starts.last == units, "the index counts \(String(describing: idx.u16Starts.last)) UTF-16 units of \(units)")
        for (a, b) in zip(idx.selStarts, idx.selStarts.dropFirst()) { try FuzzRun.check(a <= b, "selection starts \(a) then \(b)") }
        try FuzzRun.check(l.totalLines >= 1 && l.textHeight.isFinite, "\(l.totalLines) lines, \(l.textHeight) pt")
        for b in 0..<l.blockCount { try FuzzRun.check(l.lines(ofBlock: b) >= 0, "block \(b) has \(l.lines(ofBlock: b)) lines") }
    }

    /// Draws a few tiles (one past a block's last tile included, which draws nothing) and queries the
    /// layout with positions that may come from a newer, longer text.
    static func drawAndProbe(_ l: LongTextLayout, outgoing: Bool, _ rng: inout FuzzRNG) throws {
        guard l.blockCount > 0 else { return }
        let width = l.size(scale: 1).width
        for _ in 0..<3 {
            let block = l.blockLayout(rng.below(l.blockCount))
            let chunks = (block.lineCount + TiledBubble.linesPerTile - 1) / TiledBubble.linesPerTile
            _ = TiledBubble.render(block, chunk: rng.below(chunks + 1), outgoing: outgoing, width: width, scale: 1)
        }
        let height = Double(l.textHeight)
        for _ in 0..<4 {
            let y = CGFloat(rng.double(in: -20...(height * 1.5 + 20)))
            let o = l.offset(at: CGPoint(x: CGFloat(rng.double(in: -20...700)), y: y))
            try FuzzRun.check(o >= 0 && o <= l.selectionLength, "offset \(o) is outside \(l.selectionLength)")
            let range = NSRange(location: rng.int(in: 0...(l.selectionLength + 64)), length: rng.int(in: 0...512))
            _ = l.rects(for: range, visible: y...(y + 900))
            _ = l.substring(range)
            _ = l.selectionBlock(range.location)
            _ = l.textY(of: l.anchor(atTextY: y))
        }
    }

    /// A long text: at least `LongText.minBytes` of one shape, then hostile text.
    static func longText(_ rng: inout FuzzRNG) -> String {
        FuzzText.sized(bytes: rng.int(in: (LongText.minBytes + 64)...(24 << 10)), &rng) + long.text(&rng)
    }

    /// The app's path: `LongTextStore` finds a streamed text's previous index and keeps its blocks. The
    /// previous token's layout (retired by the store) is drawn and queried after the new one is measured.
    static func longStreamStep(_ rng: inout FuzzRNG) throws {
        let whole = longText(&rng)
        let width = paneWidths[rng.below(paneWidths.count)]
        let outgoing = rng.bool()
        var previous: LongTextLayout?
        for prefix in FuzzText.stream(whole, steps: 1 + rng.below(6), &rng) {
            let text = rng.oneIn(4) ? long.edit(prefix, &rng) : prefix
            guard LongText.isLong(text) else { continue }
            let l = LongTextStore.shared.layout(text, width: width)
            l.measureNow(0..<l.blockCount)
            try check(l, of: text)
            if let previous { try drawAndProbe(previous, outgoing: outgoing, &rng) }
            try drawAndProbe(l, outgoing: outgoing, &rng)
            previous = l
        }
    }

    @Test(.timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes)))
    func aLongStreamEditedBetweenMeasureAndDrawDoesNotTrap() throws {
        try Self.run("HomeMarkdown.longStream", seed: 0x10_6573, iterations: 30).forEach { rng in
            try Self.longStreamStep(&rng)
        }
    }

    /// Long Markdown in tiles (`MarkdownLong`, behind `--long-markdown` in the app): an index built on its
    /// predecessor's blocks when the text extends it, the layout carried over and maybe provisional (the tail
    /// keeps its old count until measured), the old layout retired but still drawn.
    static func longMarkdownStep(_ rng: inout FuzzRNG) throws {
        let whole = longText(&rng)
        let width = paneWidths[rng.below(paneWidths.count)]
        let outgoing = rng.bool()
        var previous: LongTextLayout?
        for prefix in FuzzText.stream(whole, steps: 1 + rng.below(6), &rng) {
            let text = rng.oneIn(4) ? long.edit(prefix, &rng) : prefix
            let idx: LongTextIndex
            var keep: Int?
            if let old = previous?.index, old.blockCount > 0, text.utf8.starts(with: old.text.utf8) {
                keep = old.blockCount - 1
                idx = LongTextIndex.build(text, lineage: old.lineage, prefix: old, keep: old.blockCount - 1, markdown: true)
            } else {
                idx = LongTextIndex.build(text, lineage: nextLineage(), markdown: true)
            }
            // Line counts carry over only to an index built on the old one (the store's rule).
            let l = LongTextLayout(index: idx, width: width, carry: keep == nil ? nil : previous, markdown: true,
                                   provisional: rng.bool() ? keep : nil)
            previous?.retired = true
            l.measureNow(0..<l.blockCount)
            try check(l, of: text)
            if let previous { try drawAndProbe(previous, outgoing: outgoing, &rng) }
            try drawAndProbe(l, outgoing: outgoing, &rng)
            previous = l
        }
        previous?.retired = true
    }

    @Test(.timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes)))
    func longMarkdownTilesStreamWithoutTrapping() throws {
        try Self.run("HomeMarkdown.longMarkdown", seed: 0x10_63D0, iterations: 30).forEach { rng in
            try Self.longMarkdownStep(&rng)
        }
    }

    // MARK: - Time budget

    /// What a pane draws of a long text at a scroll position: the tiles of 900 pt (57 lines) from `first`.
    static func drawScreen(_ l: LongTextLayout, fromLine first: Int, width: CGFloat, outgoing: Bool) {
        let n = TiledBubble.linesPerTile
        var line = max(0, first)
        let end = min(l.totalLines, line + 57)
        while line < end {
            let b = l.block(containingLine: line)
            let top = l.firstLine(ofBlock: b)
            let chunk = max(0, line - top) / n
            _ = TiledBubble.render(l.blockLayout(b), chunk: chunk, outgoing: outgoing, width: width, scale: 2)
            line = max(line + 1, top + (chunk + 1) * n)
        }
    }

    /// Budget attempts timed in this process; each one's widths come from it (``budgetWidths()``).
    static var budgetAttemptSerial = 0

    /// A short-path wrap width and a long-path pane width that no earlier call in this process gave and no
    /// other test of the suite uses, so no block of a timed attempt comes from `MarkdownLayoutEngine`'s
    /// process-wide cache (keyed by block content and width). The short width grows by 1/1024 pt per
    /// attempt from 358.4 pt. The pane width steps 1/4 pt through [761, 1001) pt: its column (rounded to
    /// 0.1 pt) moves 0.16 pt a step through [445.4, 602.4) pt, clear of ``columns`` and of the columns of
    /// ``paneWidths``; when a pane width comes back, 960 attempts of at least 16 blocks (64 KiB in 4 KiB
    /// blocks) have pushed its blocks out of the cache's 2048 entries.
    static func budgetWidths() -> (short: CGFloat, pane: CGFloat) {
        budgetAttemptSerial += 1
        return (358.4 + CGFloat(budgetAttemptSerial) / 1024, 761 + CGFloat(budgetAttemptSerial % 960) / 4)
    }

    /// One 64 KiB text of one shape: its index, every block measured and the tiles of its first and last
    /// screen, within the budget; or, one time in three, an 8 KiB text through the short Markdown path.
    /// Every attempt lays out at widths of its own (``budgetWidths()``), so each one costs a first render.
    static func budgetStep(_ rng: inout FuzzRNG) throws {
        let outgoing = rng.bool()
        if rng.oneIn(3) {
            let source = FuzzText.sized(bytes: LongText.minBytes, &rng)
            try budget.check("Home Markdown render", bytes: source.utf8.count) { _ in
                let md = MarkdownLayoutEngine.layout(Markdown.parse(source), source: source, maxWidth: budgetWidths().short)
                if let ctx = context() { MarkdownDraw.draw(ctx, md, body: CGRect(origin: .zero, size: md.size), outgoing: outgoing) }
            }
            return
        }
        let source = FuzzText.sized(bytes: 64 << 10, &rng)
        let markdown = rng.bool()
        // LongTextLayout.init queues every block on `measureQueue`; held while an attempt runs, those
        // operations cannot fill BlockLayoutCache under the timed `measureNow`, and once the attempt's
        // layout is retired they return without measuring.
        let queue = LongTextLayout.measureQueue
        queue.isSuspended = true
        defer { queue.isSuspended = false }
        try budget.check("Home long text render", bytes: source.utf8.count) { _ in
            // A new lineage: no block layout from BlockLayoutCache (keyed by lineage and column).
            let l = LongTextLayout(index: LongTextIndex.build(source, lineage: nextLineage(), markdown: markdown),
                                   width: budgetWidths().pane, markdown: markdown)
            defer { l.retired = true }
            l.measureNow(0..<l.blockCount)
            let width = l.size(scale: 2).width
            drawScreen(l, fromLine: 0, width: width, outgoing: outgoing)
            drawScreen(l, fromLine: l.totalLines - 57, width: width, outgoing: outgoing)
        }
    }

    @Test(
        .enabled(if: HomeMarkdownRenderFuzzTests.optimized,
                 "the 50 ms budget holds for an optimized build: swift test -c release -Xswiftc -enable-testing"),
        .timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes))
    )
    func a64KiBRenderTakesUnder50ms() throws {
        try Self.run("HomeMarkdown.budget", seed: 0xB0D6_E7ED, iterations: 18).forEach { rng in
            try Self.budgetStep(&rng)
        }
    }

    // MARK: - libFuzzer entry

    /// One input, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        if rng.bool() { try markdownStep(&rng) } else { try streamStep(&rng) }
    }

    @Test(.timeLimit(.minutes(HomeMarkdownRenderFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("HomeMarkdown.oneInput", seed: 0x0E1E_3D, iterations: 64)
        let seeds = [Data([0]), Data([1]), Data("```swift\r\nlet a = 1\n| a | b |\n|---|\n\u{1F468}\u{200D}\u{1F469} **b".utf8)]
        try run.forEachInput(run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }
}
