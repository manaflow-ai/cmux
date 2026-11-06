import CoreGraphics
@testable import CmuxNextLayout
import Foundation
import Testing

/// The rules of a springing close (`ClosingPanesRules`: which panes border a closing pane, the gaps it keeps, where each
/// side shows per frame, the camera carries, the panes nothing moves over and a taken-back close's velocities) over
/// seeded scripts of closes, against the answers recorded in
/// `cmux-tui/crates/cmux-layout-reducer/tests/data/closing_panes_corpus.txt`. The Rust port (cmux-layout-reducer
/// `closing_panes`, its test `closing_panes_corpus`) replays the same file, so the two are proven equal before the app
/// calls Rust (swift-logic owner, step A). Each line is one call: its inputs, its answer and a hash of the whole state
/// after it (every side, travel and carry), so a difference anywhere in the state fails the line. Answers and state are
/// written as IEEE-754 bit patterns, so the comparison is exact.
///
/// `recordCorpus` writes the file (from the Swift rules) when `ClosingPanesCorpusTests.record` is true; it is false in a
/// committed tree.
struct ClosingPanesCorpusTests {
    nonisolated static let record = false

    static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cmux-tui/crates/cmux-layout-reducer/tests/data/closing_panes_corpus.txt")
    }

    @Test(.enabled(if: Self.record))
    func recordCorpus() throws {
        var lines = ["# closing_panes corpus: one call per line, `inputs => answer state-hash`; S starts a script. Inputs are decimal",
                     "# (exact), answers and state are f64 bit patterns in hex, - is none. See ClosingPanesCorpusTests.swift."]
        var random = ClosingPanesRandom(seed: 0xC105_E2026_1104)
        for _ in 0 ..< 160 {
            var rules = ClosingPanesRules()
            lines.append("S")
            for op in Self.script(&random) { lines.append(Self.line(op, &rules)) }
        }
        try FileManager.default.createDirectory(at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: Self.fixture, atomically: true, encoding: .utf8)
    }

    /// Every call of the fixture: the Swift rules give the recorded answer and state.
    @Test(.enabled(if: !Self.record))
    func corpusMatchesTheFixture() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        var rules = ClosingPanesRules()
        var calls: [String: Int] = [:], answered: [String: Int] = [:]
        for raw in text.split(separator: "\n") where !raw.hasPrefix("#") {
            if raw == "S" {
                rules = ClosingPanesRules()
                continue
            }
            let parts = raw.components(separatedBy: " => ")
            try #require(parts.count == 2, "bad line: \(raw)")
            var fields = Fields(parts[0])
            let op = try Self.read(&fields)
            let got = Self.line(op, &rules).components(separatedBy: " => ")[1]
            #expect(got == parts[1], "\(parts[0].prefix(120))")
            let kind = String(parts[0].prefix(1))
            calls[kind, default: 0] += 1
            if !parts[1].hasPrefix("- "), !parts[1].hasPrefix("0 ") { answered[kind, default: 0] += 1 }
        }
        // Every call kind, and answers that move: the corpus is not empty or trivial.
        for (kind, least) in ["B": 200, "T": 160, "R": 600, "C": 40, "K": 20, "Y": 20, "X": 20, "D": 10] {
            #expect(calls[kind, default: 0] >= least, "\(kind): \(calls[kind, default: 0]) calls")
        }
        #expect(answered["R", default: 0] >= 500)
        #expect(answered["T", default: 0] >= 20)
        #expect(answered["X", default: 0] >= 15)
    }

    // MARK: Calls

    enum Op {
        case begin(pane: UInt64, shown: ClosingPanesRules.Edges, maxGap: CGFloat, viewShift: CGFloat?,
                   panes: [ClosingPanesRules.PaneFact], handles: [ClosingPanesRules.HandleFact])
        case settle(frames: [ClosingPanesRules.FrameFact], rows: [ClosingPanesRules.RowTravel])
        case rects(frames: [ClosingPanesRules.FrameFact], rows: [ClosingPanesRules.RowTravel])
        case carry(drift: CGFloat, viewShift: CGFloat?)
        case settleCarried(shift: CGFloat)
        case shiftY(column: UInt64, delta: CGFloat)
        case remove(pane: UInt64, frames: [ClosingPanesRules.FrameFact])
        case drop(pane: UInt64)
    }

    /// `op`'s inputs, the answer `rules` gives and the hash of its state after the call.
    static func line(_ op: Op, _ rules: inout ClosingPanesRules) -> String {
        let inputs: [String], answer: String
        switch op {
        case let .begin(pane, shown, maxGap, viewShift, panes, handles):
            inputs = ["B", "\(pane)"] + edges(shown) + [dec(maxGap), viewShift.map(dec) ?? "-", "\(panes.count)"]
                + panes.flatMap { ["\($0.id)"] + edges($0.edges) + [flag($0.scrolls), "\($0.area)", "\($0.rowColumn)"] }
                + ["\(handles.count)"]
                + handles.flatMap { handle -> [String] in
                    ["\(handle.kind.rawValue)", flag(handle.horizontal)] + edges(handle.hit)
                        + [dec(handle.midX), dec(handle.midY), flag(handle.kept), flag(handle.fixedSplit), "\(handle.area)",
                           flag(handle.docked), "\(handle.column)"]
                }
            answer = flag(rules.begin(pane, shown: shown, panes: panes, handles: handles, maxGap: maxGap, viewShift: viewShift))
        case let .settle(frames, rows):
            inputs = ["T"] + Self.frames(frames) + Self.rows(rows)
            let still = rules.settle(frames: frames, rows: rows).sorted()
            answer = still.isEmpty ? "-" : still.map(String.init).joined(separator: ",")
        case let .rects(frames, rows):
            inputs = ["R"] + Self.frames(frames) + Self.rows(rows)
            let placed = rules.rects(frames: frames, rows: rows)
            answer = placed.isEmpty ? "-" : placed.map { "\($0.0):" + rect($0.1) }.joined(separator: ";")
        case let .carry(drift, viewShift):
            inputs = ["C", dec(drift), viewShift.map(dec) ?? "-"]
            rules.carry(drift: drift, viewShift: viewShift)
            answer = "-"
        case let .settleCarried(shift):
            inputs = ["K", dec(shift)]
            rules.settleCarried(stripShift: shift)
            answer = "-"
        case let .shiftY(column, delta):
            inputs = ["Y", "\(column)", dec(delta)]
            rules.shiftY(inRowColumn: column, by: delta)
            answer = "-"
        case let .remove(pane, frames):
            inputs = ["X", "\(pane)"] + Self.frames(frames)
            answer = rules.remove(pane, frames: frames).map {
                rect($0.rect) + "," + [$0.vx, $0.vw, $0.vy, $0.vh].map(hex).joined(separator: ",")
            } ?? "-"
        case let .drop(pane):
            inputs = ["D", "\(pane)"]
            rules.drop(pane)
            answer = "-"
        }
        return inputs.joined(separator: " ") + " => " + answer + " " + state(rules)
    }

    /// The whole state of `rules` as one string (every entry by pane, each side's neighbours, gap, place, travel start and
    /// end, the carry and the row travel; the close order and the panes awaiting the cameras), hashed (FNV-1a, 64 bits).
    /// `closing_panes_corpus` builds the same string.
    static func state(_ rules: ClosingPanesRules) -> String {
        func side(_ side: ClosingPanesRules.Side) -> String {
            [side.neighbours.map(String.init).joined(separator: ","), hex(side.gap), hex(side.fixed), side.start.map(hex) ?? "-",
             side.end.map(hex) ?? "-"].joined(separator: ";")
        }
        var text = ""
        for pane in rules.entries.keys.sorted() {
            guard let entry = rules.entries[pane] else { continue }
            let carried = entry.carriedShown.map { hex($0.minX) + "," + hex($0.maxX) } ?? "-"
            let travel = entry.rowTravel.map { hex($0.start) + "," + hex($0.target) } ?? "-"
            text += ["\(pane)", side(entry.minX), side(entry.maxX), side(entry.minY), side(entry.maxY), flag(entry.scrolls),
                     "\(entry.rowColumn)", carried, travel].joined(separator: "|") + "\n"
        }
        text += "order:" + rules.order.map(String.init).joined(separator: ",") + "\n"
        text += "await:" + rules.awaiting.sorted().map(String.init).joined(separator: ",") + "\n"
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    // MARK: Reading a line

    struct Fields {
        var words: [Substring]
        var index = 0
        init(_ text: String) { words = text.split(separator: " ") }

        mutating func word() throws -> String {
            try #require(index < words.count, "short line")
            defer { index += 1 }
            return String(words[index])
        }

        mutating func double() throws -> CGFloat {
            let text = try word()
            return try #require(Double(text), "not a number: \(text)")
        }

        mutating func optional() throws -> CGFloat? {
            let text = try word()
            if text == "-" { return nil }
            return try #require(Double(text), "not a number: \(text)")
        }

        mutating func id() throws -> UInt64 {
            let text = try word()
            return try #require(UInt64(text), "not an id: \(text)")
        }

        mutating func count() throws -> Int {
            let value = try id()
            return Int(value)
        }
        mutating func bool() throws -> Bool { try word() == "1" }

        mutating func edges() throws -> ClosingPanesRules.Edges {
            ClosingPanesRules.Edges(minX: try double(), maxX: try double(), minY: try double(), maxY: try double())
        }

        mutating func frames() throws -> [ClosingPanesRules.FrameFact] {
            try (0 ..< count()).map { _ in
                ClosingPanesRules.FrameFact(id: try id(), now: try edges(), target: try edges(), moving: try bool(), vx: try double(),
                                            vy: try double(), vw: try double(), vh: try double())
            }
        }

        mutating func rows() throws -> [ClosingPanesRules.RowTravel] {
            try (0 ..< count()).map { _ in ClosingPanesRules.RowTravel(column: try id(), now: try double(), target: try double()) }
        }
    }

    static func read(_ f: inout Fields) throws -> Op {
        switch try f.word() {
        case "B":
            let pane = try f.id(), shown = try f.edges(), maxGap = try f.double(), viewShift = try f.optional()
            let panes = try (0 ..< f.count()).map { _ in
                ClosingPanesRules.PaneFact(id: try f.id(), edges: try f.edges(), scrolls: try f.bool(), area: try f.id(), rowColumn: try f.id())
            }
            let handles = try (0 ..< f.count()).map { _ in
                let kind = try #require(ClosingPanesRules.HandleKind(rawValue: UInt8(try f.id())))
                return ClosingPanesRules.HandleFact(kind: kind, horizontal: try f.bool(), hit: try f.edges(), midX: try f.double(),
                                                    midY: try f.double(), kept: try f.bool(), fixedSplit: try f.bool(), area: try f.id(),
                                                    docked: try f.bool(), column: try f.id())
            }
            return .begin(pane: pane, shown: shown, maxGap: maxGap, viewShift: viewShift, panes: panes, handles: handles)
        case "T": return .settle(frames: try f.frames(), rows: try f.rows())
        case "R": return .rects(frames: try f.frames(), rows: try f.rows())
        case "C": return .carry(drift: try f.double(), viewShift: try f.optional())
        case "K": return .settleCarried(shift: try f.double())
        case "Y": return .shiftY(column: try f.id(), delta: try f.double())
        case "X": return .remove(pane: try f.id(), frames: try f.frames())
        case "D": return .drop(pane: try f.id())
        case let other:
            Issue.record("unknown call \(other)")
            throw CancellationError()
        }
    }

    // MARK: Writing

    nonisolated static func hex(_ value: CGFloat) -> String { String(Double(value).bitPattern, radix: 16) }
    /// An input as Swift's shortest decimal that reads back to the same double (Rust's parse is correctly rounded, so it
    /// reads the same bits).
    nonisolated static func dec(_ value: CGFloat) -> String { "\(Double(value))" }
    nonisolated static func flag(_ value: Bool) -> String { value ? "1" : "0" }
    static func edges(_ e: ClosingPanesRules.Edges) -> [String] { [dec(e.minX), dec(e.maxX), dec(e.minY), dec(e.maxY)] }
    static func rect(_ r: ClosingPanesRules.Placed) -> String { [r.x, r.y, r.width, r.height].map(hex).joined(separator: ",") }

    static func frames(_ frames: [ClosingPanesRules.FrameFact]) -> [String] {
        ["\(frames.count)"] + frames.flatMap { f -> [String] in
            ["\(f.id)"] + edges(f.now) + edges(f.target) + [flag(f.moving), dec(f.vx), dec(f.vy), dec(f.vw), dec(f.vh)]
        }
    }

    static func rows(_ rows: [ClosingPanesRules.RowTravel]) -> [String] {
        ["\(rows.count)"] + rows.flatMap { ["\($0.column)", dec($0.now), dec($0.target)] }
    }

    // MARK: Scripts

    /// One screen: its panes (in the order the rules get them) and handles, with the column gap.
    struct Layout {
        var panes: [ClosingPanesRules.PaneFact] = []
        var handles: [ClosingPanesRules.HandleFact] = []
        var rowColumns: [UInt64] = []
        var maxGap: CGFloat = 0
    }

    /// A screen of strip columns (each a stack of panes, some split side by side, some a row column, some in a scroll
    /// area), sometimes with a docked column, and its handles (some kept, a few that border nothing).
    static func layout(_ r: inout ClosingPanesRandom) -> Layout {
        var layout = Layout()
        var usedIDs = Set<UInt64>()
        func id(_ range: ClosedRange<UInt64>) -> UInt64 {
            while true {
                let value = r.int(range)
                if usedIDs.insert(value).inserted { return value }
            }
        }
        let columnGap = r.chance(0.2) ? 0 : r.q(0 ... 20, step: 0.5)
        let dividerGap = r.pick([1, 2, 4, 6] as [CGFloat])
        let thickness = r.q(4 ... 10, step: 0.5)
        let height = r.q(300 ... 900, step: 0.25)
        let top = r.q(-50 ... 50, step: 0.25)
        layout.maxGap = Swift.max(columnGap, thickness) + 1
        var x = r.q(-200 ... 200, step: 0.25)
        func hitX(_ center: CGFloat, y0: CGFloat, y1: CGFloat) -> (ClosingPanesRules.Edges, CGFloat, CGFloat) {
            let e = ClosingPanesRules.Edges(minX: center - thickness / 2, maxX: center + thickness / 2, minY: y0, maxY: y1)
            return (e, center, (y0 + y1) / 2)
        }
        func hitY(_ center: CGFloat, x0: CGFloat, x1: CGFloat) -> (ClosingPanesRules.Edges, CGFloat, CGFloat) {
            let e = ClosingPanesRules.Edges(minX: x0, maxX: x1, minY: center - thickness / 2, maxY: center + thickness / 2)
            return (e, (x0 + x1) / 2, center)
        }
        func handle(_ kind: ClosingPanesRules.HandleKind, horizontal: Bool, _ h: (ClosingPanesRules.Edges, CGFloat, CGFloat),
                    fixed: Bool = false, area: UInt64 = 0, docked: Bool = false, column: UInt64 = 0) {
            layout.handles.append(.init(kind: kind, horizontal: horizontal, hit: h.0, midX: h.1, midY: h.2, kept: r.chance(0.6),
                                        fixedSplit: fixed, area: area, docked: docked, column: column))
        }
        /// A column of stacked panes from `x0` to `x1`; returns nothing (adds panes and handles).
        func column(x0: CGFloat, x1: CGFloat, scrolls: Bool) {
            let rowColumn: UInt64 = scrolls && r.chance(0.4) ? id(1000 ... 1999) : 0
            if rowColumn != 0 { layout.rowColumns.append(rowColumn) }
            let area: UInt64 = scrolls && r.chance(0.2) ? id(2000 ... 2999) : 0
            let count = Int(r.int(1 ... 3))
            var cuts: [CGFloat] = (1 ..< count).map { _ in r.q(0.2 ... 0.8, step: 1.0 / 64) }.sorted()
            cuts = [0] + cuts + [1]
            for row in 0 ..< count {
                let y0 = top + height * cuts[row] + (row == 0 ? 0 : dividerGap / 2)
                let y1 = top + height * cuts[row + 1] - (row == count - 1 ? 0 : dividerGap / 2)
                if r.chance(0.25), x1 - x0 > 60 {
                    let mid = x0 + (x1 - x0) * r.q(0.3 ... 0.7, step: 1.0 / 32)
                    layout.panes.append(.init(id: id(1 ... 500), edges: .init(minX: x0, maxX: mid - dividerGap / 2, minY: y0, maxY: y1),
                                              scrolls: scrolls, area: area, rowColumn: rowColumn))
                    layout.panes.append(.init(id: id(1 ... 500), edges: .init(minX: mid + dividerGap / 2, maxX: x1, minY: y0, maxY: y1),
                                              scrolls: scrolls, area: area, rowColumn: rowColumn))
                    handle(.split, horizontal: true, hitX(mid, y0: y0, y1: y1), fixed: !scrolls, area: r.chance(0.1) ? id(3000 ... 3999) : area)
                } else {
                    layout.panes.append(.init(id: id(1 ... 500), edges: .init(minX: x0, maxX: x1, minY: y0, maxY: y1), scrolls: scrolls,
                                              area: area, rowColumn: rowColumn))
                }
                if row < count - 1 {
                    let center = top + height * cuts[row + 1]
                    if rowColumn != 0 {
                        handle(.rowEdge, horizontal: false, hitY(center, x0: x0, x1: x1), column: rowColumn)
                    } else {
                        handle(.split, horizontal: false, hitY(center, x0: x0, x1: x1), fixed: !scrolls,
                               area: r.chance(0.1) ? id(3000 ... 3999) : area)
                    }
                }
            }
        }
        let columns = Int(r.int(1 ... 4))
        for index in 0 ..< columns {
            let width = r.q(150 ... 600, step: 0.25)
            column(x0: x, x1: x + width, scrolls: true)
            x += width
            if index < columns - 1 {
                handle(.columnEdge, horizontal: true, hitX(x + columnGap / 2, y0: top, y1: top + height))
                x += columnGap
            }
        }
        if r.chance(0.35) {
            let gap = r.q(0 ... 12, step: 0.5)
            handle(.columnEdge, horizontal: true, hitX(x + gap / 2, y0: top, y1: top + height), docked: true)
            let width = r.q(120 ... 400, step: 0.25)
            column(x0: x + gap, x1: x + gap + width, scrolls: false)
        }
        for _ in 0 ..< Int(r.int(0 ... 2)) {
            let center = r.q(-200 ... 1500, step: 0.25)
            handle(r.pick([.split, .columnEdge, .rowEdge] as [ClosingPanesRules.HandleKind]), horizontal: r.chance(0.5),
                   hitX(center, y0: top, y1: top + height), fixed: r.chance(0.3), area: 0, docked: r.chance(0.3),
                   column: layout.rowColumns.first ?? 77_777)
        }
        layout.panes.shuffle(using: &r)
        layout.handles.shuffle(using: &r)
        return layout
    }

    /// A live pane's frame: where it shows and where it springs to.
    struct Live {
        var id: UInt64
        var start: ClosingPanesRules.Edges
        var target: ClosingPanesRules.Edges
        var velocity: (CGFloat, CGFloat, CGFloat, CGFloat)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func moved(_ e: ClosingPanesRules.Edges, _ r: inout ClosingPanesRandom) -> ClosingPanesRules.Edges {
        if r.chance(0.4) { return e }
        let a = e.minX + r.q(-200 ... 200, step: 0.25), b = e.maxX + r.q(-200 ... 200, step: 0.25)
        let c = e.minY + (r.chance(0.6) ? 0 : r.q(-150 ... 150, step: 0.25)), d = e.maxY + (r.chance(0.6) ? 0 : r.q(-150 ... 150, step: 0.25))
        return .init(minX: Swift.min(a, b), maxX: Swift.max(a, b), minY: Swift.min(c, d), maxY: Swift.max(c, d))
    }

    static func script(_ r: inout ClosingPanesRandom) -> [Op] {
        var layout = Self.layout(&r)
        var ops: [Op] = []
        guard let first = layout.panes.randomElement(using: &r) else { return ops }
        var closing: [UInt64] = []
        func begin(_ pane: ClosingPanesRules.PaneFact) {
            let drift: CGFloat = r.chance(0.5) ? 0 : r.q(-40 ... 40, step: 0.25)
            let shown = ClosingPanesRules.Edges(minX: pane.edges.minX + drift, maxX: pane.edges.maxX + drift, minY: pane.edges.minY,
                                                maxY: pane.edges.maxY)
            ops.append(.begin(pane: pane.id, shown: shown, maxGap: layout.maxGap,
                              viewShift: r.chance(0.5) ? nil : r.q(-100 ... 100, step: 0.25), panes: layout.panes, handles: layout.handles))
            closing.append(pane.id)
            layout.panes.removeAll { $0.id == pane.id }
        }
        if r.chance(0.1) {
            ops.append(.begin(pane: 9999, shown: first.edges, maxGap: layout.maxGap, viewShift: nil, panes: layout.panes, handles: layout.handles))
        }
        begin(first)
        var lives = layout.panes.map { pane in
            Live(id: pane.id, start: pane.edges, target: moved(pane.edges, &r),
                 velocity: r.chance(0.5) ? (0, 0, 0, 0)
                     : (r.q(-50 ... 50, step: 0.5), r.q(-50 ... 50, step: 0.5), r.q(-50 ... 50, step: 0.5), r.q(-50 ... 50, step: 0.5)))
        }
        var travels: [(column: UInt64, start: CGFloat, target: CGFloat)] = layout.rowColumns.compactMap { column in
            r.chance(0.6) ? (column, r.q(-100 ... 100, step: 0.25), r.chance(0.2) ? 0 : r.q(-100 ... 100, step: 0.25)) : nil
        }
        let steps = Int(r.pick([2, 4, 8] as [UInt64]))
        var t: CGFloat = 0
        func frames() -> [ClosingPanesRules.FrameFact] {
            lives.filter { !closing.contains($0.id) }.map { live in
                let now = ClosingPanesRules.Edges(minX: lerp(live.start.minX, live.target.minX, t), maxX: lerp(live.start.maxX, live.target.maxX, t),
                                                  minY: lerp(live.start.minY, live.target.minY, t), maxY: lerp(live.start.maxY, live.target.maxY, t))
                let still: CGFloat = t >= 1 ? 0 : 1
                let v = (live.velocity.0 * still, live.velocity.1 * still, live.velocity.2 * still, live.velocity.3 * still)
                let moving = now != live.target || v.0 != 0 || v.1 != 0 || v.2 != 0 || v.3 != 0
                return .init(id: live.id, now: now, target: live.target, moving: moving, vx: v.0, vy: v.1, vw: v.2, vh: v.3)
            }
        }
        func rows() -> [ClosingPanesRules.RowTravel] {
            travels.map { .init(column: $0.column, now: lerp($0.start, $0.target, t), target: $0.target) }
        }
        ops.append(.settle(frames: frames(), rows: rows()))
        for step in 1 ... steps {
            t = CGFloat(step) / CGFloat(steps)
            if r.chance(0.15), let index = travels.indices.randomElement(using: &r) {
                let now = lerp(travels[index].start, travels[index].target, t)
                travels[index] = (travels[index].column, now, r.q(-100 ... 100, step: 0.25))
            }
            if r.chance(0.15), let index = lives.indices.randomElement(using: &r) {
                lives[index].start = frames().first { $0.id == lives[index].id }?.now ?? lives[index].start
                lives[index].target = moved(lives[index].target, &r)
            }
            if r.chance(0.2) {
                ops.append(.carry(drift: r.chance(0.3) ? 0 : r.q(-30 ... 30, step: 0.25), viewShift: r.chance(0.4) ? nil : r.q(-100 ... 100, step: 0.25)))
                if r.chance(0.6) { ops.append(.settleCarried(shift: r.q(-100 ... 100, step: 0.25))) }
            }
            if r.chance(0.15) {
                ops.append(.shiftY(column: layout.rowColumns.randomElement(using: &r) ?? 1234, delta: r.q(-60 ... 60, step: 0.25)))
            }
            if r.chance(0.2), closing.count < 3, let next = layout.panes.randomElement(using: &r) {
                begin(next)
                ops.append(.settle(frames: frames(), rows: rows()))
            }
            ops.append(.rects(frames: frames(), rows: rows()))
            if r.chance(0.06), let pane = closing.randomElement(using: &r) {
                ops.append(.remove(pane: pane, frames: frames()))
                closing.removeAll { $0 == pane }
            } else if r.chance(0.04), let pane = closing.randomElement(using: &r) {
                ops.append(.drop(pane: pane))
                closing.removeAll { $0 == pane }
            }
        }
        if let pane = closing.randomElement(using: &r), r.chance(0.5) {
            ops.append(.remove(pane: pane, frames: frames()))
        } else if r.chance(0.3) {
            ops.append(.drop(pane: closing.first ?? 9999))
        }
        return ops
    }
}

/// SplitMix64: a seeded generator, so the recorded scripts are the same on every run.
nonisolated struct ClosingPanesRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<UInt64>) -> UInt64 { range.lowerBound + next() % (range.upperBound - range.lowerBound + 1) }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func pick<T>(_ values: [T]) -> T { values[Int(next() % UInt64(values.count))] }

    /// A multiple of `step` in `range`.
    mutating func q(_ range: ClosedRange<CGFloat>, step: CGFloat) -> CGFloat {
        let steps = UInt64(((range.upperBound - range.lowerBound) / step).rounded(.down))
        return range.lowerBound + CGFloat(int(0 ... steps)) * step
    }
}
