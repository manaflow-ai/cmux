import CmuxFuzzSupport
import CmuxHomeCore
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import CmuxHomeRender

/// Seeded fuzz of the Home render core's text path (plans/cmux-next/chrome-parity/p10-stability.md, task 028):
/// hostile text (`FuzzText`: Markdown syntax, open fences, ZWJ emoji, combining marks, CRLF, huge lines)
/// measured with Core Text (`TextLayout.make`) and drawn (`PartDrawing.drawText`) at odd wrap widths, with
/// mention ranges as the wire may send them (any `Int`s), and a transcript whose text is edited between its
/// measurement and its bitmap's draw: `RowBitmaps` renders a row spec in a detached job, so a job started for
/// one update draws after the next update measured the edited text. Chrome bounds the same work with
/// libFuzzer's per-input timeout and slow-unit report (testing/libfuzzer/README.md); here the bound is the
/// Home budget.
///
/// Properties: no trap (a trap ends the run, so a finished run is the proof); every layout covers its text
/// with in-range lines; a kept layout (`TextLayout.isValid`) wraps as a new one would; after an edit every
/// text row is laid out from the edited text and mentions (no measurement kept from the old text); a 64 KiB
/// render (measure plus draw) takes under 50 ms in an optimized build, on every timed attempt.
///
/// It runs only with `CMUX_HOME_RENDER_FUZZ=1`; agents run it on the fleet, CI does not (Lawrence 2026-10-23):
///
/// ```
/// CMUX_HOME_RENDER_FUZZ=1 swift test -c release -Xswiftc -enable-testing --filter HomeRenderFuzzTests
/// CMUX_HOME_RENDER_FUZZ=1 CMUX_FUZZ_DEADLINE=$(( $(date +%s) + 300 )) swift test -c release -Xswiftc -enable-testing --filter HomeRenderFuzzTests
/// ```
///
/// The runs are CmuxFuzzSupport `FuzzRun`s: `CMUX_FUZZ_SEED` and `CMUX_FUZZ_ITERATIONS` replay a failure,
/// and with `CMUX_FUZZ_ARTIFACTS` set a trap leaves its case behind (`HomeRender.<run>.inflight`). The suite
/// is serialized, so each of its ``runCount`` runs gets an equal share of `CMUX_FUZZ_DEADLINE`.
@MainActor
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CMUX_HOME_RENDER_FUZZ"] == "1",
        "set CMUX_HOME_RENDER_FUZZ=1; agents run it on the fleet (Lawrence 2026-10-23)"
    )
)
struct HomeRenderFuzzTests {
    /// Two minutes past a long run's budget, so the limit stops a hang and never a long run.
    nonisolated static let timeLimitMinutes: Int = {
        let budget = (try? FuzzEnvironment.current())?.longModeBudget(from: Date()) ?? 0
        return 2 + Int((budget / 60).rounded(.up))
    }()

    /// The suite's runs (its `@Test`s), which share a `CMUX_FUZZ_DEADLINE`.
    static let runCount = 4

    /// Each run's share of `CMUX_FUZZ_DEADLINE`, fixed when the first run asks; nil without a deadline or in a replay.
    static let deadlineShare: TimeInterval? = {
        guard let environment = try? FuzzEnvironment.current(), environment.iterations == nil,
              let deadline = environment.deadline else { return nil }
        return max(deadline.timeIntervalSinceNow, 0) / Double(runCount)
    }()

    /// A run of this suite: the process's `CMUX_FUZZ_*` variables, its long mode capped at ``deadlineShare``.
    static func run(_ name: String, seed: UInt64, iterations: Int) throws(FuzzError) -> FuzzRun {
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

    static let generator = FuzzText(maxBytes: 8 << 10)
    static let transcriptText = FuzzText(maxBytes: 2 << 10)
    static let budget = FuzzBudget(perUnit: .milliseconds(50), unitBytes: 64 << 10)
    static let widths: [CGFloat] = [.nan, -.infinity, .infinity, -1, 0, 0.5, 1, 12, 117.3, 358.4, 1_000, 1e9]
    static let viewports: [CGSize] = [CGSize(width: 1, height: 1), CGSize(width: 0, height: 0), CGSize(width: 320, height: 200),
                                      CGSize(width: 4000, height: 3000), CGSize(width: 628, height: 900)]
    static let extremes = [Int.min, -1, 0, 1, Int.max]

    // MARK: - Measure and draw

    /// Mention ranges as the wire may send them: mostly near the text, sometimes any `Int`s.
    static func mentions(_ length: Int, _ rng: inout FuzzRNG) -> [NSRange] {
        (0..<rng.below(4)).map { _ -> NSRange in
            if rng.oneIn(4) {
                return NSRange(location: extremes[rng.below(extremes.count)], length: extremes[rng.below(extremes.count)])
            }
            let start = rng.int(in: 0...(length + 4))
            return NSRange(location: start, length: rng.int(in: 0...max(0, length - start + 4)))
        }
    }

    /// The layout's lines cover `text` in order: each in range, the next starting where it ends or one
    /// unit later (a hard newline is neither drawn nor measured), the last ending at the text's end.
    static func checkLayout(_ tl: TextLayout, of text: String) throws {
        let length = (text as NSString).length
        try FuzzRun.check(tl.lines.first?.range.location == 0, "the first line is \(String(describing: tl.lines.first?.range))")
        var end = 0
        for (i, line) in tl.lines.enumerated() {
            let r = line.range
            try FuzzRun.check(r.location >= 0 && r.length >= 0 && r.location <= length - r.length, "line \(i) \(r) is outside \(length) units")
            if i > 0 {
                try FuzzRun.check(r.location - end == 0 || r.location - end == 1, "line \(i) starts at \(r.location), the last ended at \(end)")
            }
            try FuzzRun.check(line.width.isFinite && line.width >= 0, "line \(i) is \(line.width) wide")
            end = r.location + r.length
        }
        try FuzzRun.check(end == length, "the lines end at \(end) of \(length) units")
        try FuzzRun.check(tl.textHeight(hard: Style.hardBreakAdvance).isFinite, "the text height is not finite")
    }

    /// Every line of `tl` shaped and drawn into a viewport-sized bitmap (lines below it are clipped, as a
    /// row bitmap's tiles would be, but still shaped).
    @discardableResult
    static func draw(_ tl: TextLayout, outgoing: Bool) -> CGImage? {
        let body = CGRect(x: 0, y: 0, width: min(tl.width, 4_000) + 2 * Style.bubblePadX, height: 600)
        return Canvas.image(size: CGSize(width: 480, height: 600), scale: 1) { ctx in
            PartDrawing.drawText(ctx, tl, in: body, outgoing: outgoing, palette: Fixtures.palette)
        }
    }

    static func measureStep(_ rng: inout FuzzRNG) throws {
        let source = generator.text(&rng)
        let bold = mentions((source as NSString).length, &rng)
        let width = widths[rng.below(widths.count)]
        let tl = TextLayout.make(source, bold: bold, maxWidth: width, font: Style.bodyFont)
        try checkLayout(tl, of: source)
        draw(tl, outgoing: rng.bool())
        // A resize keeps a layout only when it wraps the same way (MeasureCache relies on it).
        let other = widths[rng.below(widths.count)]
        guard width.isFinite, other.isFinite, width > 0, other > 0, tl.isValid(atMaxWidth: other, measuredAt: width) else { return }
        let again = TextLayout.make(source, bold: bold, maxWidth: other, font: Style.bodyFont)
        try FuzzRun.check(again.lines.map(\.range) == tl.lines.map(\.range), "a layout kept from \(width) to \(other) wraps differently")
    }

    @Test(.timeLimit(.minutes(HomeRenderFuzzTests.timeLimitMinutes)))
    func hostileTextMeasuresAndDraws() throws {
        try Self.run("HomeRender.measure", seed: 0x7E47_1A70, iterations: 300).forEach { rng in
            try Self.measureStep(&rng)
        }
    }

    // MARK: - Edits between measure and draw

    static func items(_ texts: [String], _ mentions: [[Mention]], mine: [Bool]) -> [TranscriptItem] {
        let messages = texts.indices.map { i in
            Message(id: MessageID("msg_\(i + 1)"), conversation: Fixtures.conversation, seq: Seq(i + 1),
                    clientMessageID: IdempotencyKey("key_\(i + 1)"), author: mine[i] ? Fixtures.me : Fixtures.chief,
                    parts: [.text(texts[i], mentions: mentions[i])], createdAt: Fixtures.start.addingTimeInterval(Double(i) * 30))
        }
        return Fixtures.items(messages)
    }

    static func wireMentions(_ text: String, _ rng: inout FuzzRNG) -> [Mention] {
        mentions((text as NSString).length, &rng).map { Mention(start: $0.location, length: $0.length, participant: Fixtures.chief) }
    }

    /// Every shown text part of `items` has a row laid out from that part's own text and mentions, not a
    /// measurement `MeasureCache` kept from the text before the edit, and a layout kept across a resize
    /// (`TextLayout.isValid`) has the lines a fresh layout at the current column has.
    static func checkRows(_ c: HomeController, of items: [TranscriptItem]) throws {
        let specs = Dictionary(c.scene.model.rows.filter { !$0.ghost }.map { ($0.spec.key, $0.spec) }, uniquingKeysWith: { a, _ in a })
        let column = c.scene.metrics.maxTextWidth
        for item in items {
            for (pi, part) in item.parts.enumerated() where RowBuilder.shows(part) {
                guard case .text(let text, let mentions) = part else { continue }
                let key = "part:\(item.key.rawValue):\(pi)"
                guard let tl = specs[key]?.partRow?.text else {
                    try FuzzRun.check(false, "no text row \(key) for a text of \(text.utf8.count) bytes")
                    continue
                }
                try FuzzRun.check(tl.text.utf8.elementsEqual(text.utf8),
                                  "row \(key) draws a text of \(tl.text.utf8.count) bytes for one of \(text.utf8.count)")
                try FuzzRun.check(tl.bold == mentions.map { NSRange(location: $0.start, length: $0.length) },
                                  "row \(key) bolds \(tl.bold), its mentions are \(mentions.map { ($0.start, $0.length) })")
                try checkLayout(tl, of: text)
                let fresh = TextLayout.make(text, bold: tl.bold, maxWidth: column, font: Style.bodyFont)
                try FuzzRun.check(fresh.lines.map(\.range) == tl.lines.map(\.range),
                                  "row \(key) keeps lines a fresh layout at the \(column) pt column does not have")
            }
        }
    }

    /// Updates the transcript (its rows measured), edits some texts and maybe resizes, updates again, checks
    /// that the second update's rows were laid out from the edited texts, then draws the first update's row
    /// specs (a render job started before the edit) and the second's.
    static func transcriptStep(_ c: HomeController, _ rng: inout FuzzRNG) throws {
        let count = 1 + rng.below(4)
        var texts = (0..<count).map { _ in transcriptText.text(&rng) }
        var mentionSets = texts.map { wireMentions($0, &rng) }
        let mine = (0..<count).map { _ in rng.bool() }
        c.update(items: items(texts, mentionSets, mine: mine), summary: Fixtures.summary(), typing: [], hasOlder: false)
        let measured = c.scene.model.rows.map(\.spec)
        let metrics = c.scene.metrics
        for i in texts.indices where rng.bool() {
            texts[i] = transcriptText.edit(texts[i], &rng)
            if rng.bool() { mentionSets[i] = wireMentions(texts[i], &rng) }
        }
        if rng.oneIn(3) { c.resize(to: viewports[rng.below(viewports.count)]) }
        let edited = items(texts, mentionSets, mine: mine)
        c.update(items: edited, summary: Fixtures.summary(), typing: [], hasOlder: false)
        // HomeController.update lays rows out only once the scene has a width.
        if c.scene.size.width > 0 { try checkRows(c, of: edited) }
        c.hostScrolled(to: CGFloat(rng.double(in: -2000...20000)))
        for spec in measured + c.scene.model.rows.map(\.spec) {
            let frame = RowArt.frame(spec, metrics: metrics)
            try FuzzRun.check(frame.width.isFinite && frame.height.isFinite, "row \(spec.key) has the frame \(frame)")
            let size = CGSize(width: min(max(frame.width, 1), 2_048), height: min(max(frame.height, 1), 2_048))
            _ = Canvas.image(size: size, scale: 1) { RowArt.draw(spec, palette: Fixtures.palette, $0) }
        }
    }

    @Test(.timeLimit(.minutes(HomeRenderFuzzTests.timeLimitMinutes)))
    func editsBetweenMeasureAndDrawDoNotTrap() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        try Self.run("HomeRender.edits", seed: 0xED17_5EED, iterations: 80).forEach { rng in
            try Self.transcriptStep(c, &rng)
        }
        // The scene's own render jobs (of stale and edited rows) finish inside the test.
        await c.scene.bitmaps.settled()
    }

    // MARK: - Time budget

    /// One 64 KiB text of one shape, measured and drawn within the budget.
    static func budgetStep(_ rng: inout FuzzRNG) throws {
        let source = FuzzText.sized(bytes: 64 << 10, &rng)
        let outgoing = rng.bool()
        // TextLayout.make and drawText keep no cache, so every attempt does all the work.
        try budget.check("Home text render", bytes: source.utf8.count) { _ in
            _ = draw(TextLayout.make(source, maxWidth: Style.maxTextWidth, font: Style.bodyFont), outgoing: outgoing)
        }
    }

    @Test(
        .enabled(if: HomeRenderFuzzTests.optimized, "the 50 ms budget holds for an optimized build: swift test -c release -Xswiftc -enable-testing"),
        .timeLimit(.minutes(HomeRenderFuzzTests.timeLimitMinutes))
    )
    func a64KiBRenderTakesUnder50ms() throws {
        try Self.run("HomeRender.budget", seed: 0xB0D6_E764, iterations: 18).forEach { rng in
            try Self.budgetStep(&rng)
        }
    }

    // MARK: - libFuzzer entry

    /// One input, its choices read from `data` (the libFuzzer entry).
    static func oneInput(_ data: Data) throws {
        var rng = FuzzRNG(replaying: data)
        try measureStep(&rng)
    }

    @Test(.timeLimit(.minutes(HomeRenderFuzzTests.timeLimitMinutes)))
    func oneInputTakesAnyBytes() throws {
        let run = try Self.run("HomeRender.oneInput", seed: 0x0E1E_C0DE, iterations: 64)
        let seeds = [Data([0]), Data("# a\r\n```swift\n\u{1F468}\u{200D}\u{1F469} **b".utf8)]
        try run.forEachInput(run.corpus(seeds: seeds)) { try Self.oneInput($0) }
    }
}
