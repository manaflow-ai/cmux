import CoreGraphics
@testable import CmuxNextLayout
import Foundation
import Testing

/// The keyboard resize rules (`ShownResizeRange`'s ratio, column width, dock width, column trade and row heights) over
/// a seeded corpus of inputs, against the answers recorded in
/// `cmux-tui/crates/cmux-layout-reducer/tests/data/shown_resize_corpus.txt`. The Rust port (cmux-layout-reducer
/// `shown_resize`, its test `shown_resize_corpus`) reads the same file, so the two are proven equal on every case
/// before the app calls Rust (swift-logic owner, step A). Floats are written as their IEEE-754 bit patterns, so the
/// comparison is exact.
///
/// `recordCorpus` writes the file (from the Swift rules) when `ShownResizeRangeCorpusTests.record` is true; it is
/// false in a committed tree.
struct ShownResizeRangeCorpusTests {
    nonisolated static let record = false

    static var fixture: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cmux-tui/crates/cmux-layout-reducer/tests/data/shown_resize_corpus.txt")
    }

    @Test(.enabled(if: Self.record))
    func recordCorpus() throws {
        var lines = ["# shown_resize corpus: kind inputs => outputs; floats are f64 bit patterns in hex, - is none."]
        var random = SplitMix64(seed: 0x5EED_2026_1104)
        for input in Self.ratioInputs(&random) { lines.append(Self.line(input)) }
        for input in Self.widthInputs(&random) { lines.append(Self.line(input)) }
        for input in Self.dockInputs(&random) { lines.append(Self.line(input)) }
        for input in Self.tradeInputs(&random) { lines.append(Self.line(input)) }
        for input in Self.rowInputs(&random) { lines.append(Self.line(input)) }
        try FileManager.default.createDirectory(at: Self.fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: Self.fixture, atomically: true, encoding: .utf8)
    }

    /// Every case of the fixture: the Swift rules give the recorded answer.
    @Test(.enabled(if: !Self.record))
    func corpusMatchesTheFixture() throws {
        let text = try String(contentsOf: Self.fixture, encoding: .utf8)
        var cases = 0
        for raw in text.split(separator: "\n") where !raw.hasPrefix("#") {
            let parts = raw.components(separatedBy: " => ")
            try #require(parts.count == 2, "bad line: \(raw)")
            var fields = Fields(parts[0])
            let kind = try fields.word()
            let got: String
            switch kind {
            case "ratio": got = Self.answer(try Self.readRatio(&fields))
            case "width": got = Self.answer(try Self.readWidth(&fields))
            case "dock": got = Self.answer(try Self.readDock(&fields))
            case "trade": got = Self.answer(try Self.readTrade(&fields))
            case "rows": got = Self.answer(try Self.readRows(&fields))
            default: Issue.record("unknown kind \(kind)"); continue
            }
            #expect(got == parts[1], "\(parts[0])")
            cases += 1
        }
        #expect(cases >= 2000)
    }

    // MARK: Inputs

    enum Input {
        case ratio(container: CGFloat, divider: CGFloat, minimumA: CGFloat, minimumB: CGFloat)
        case width(isColumns: Bool, isDocked: Bool, strip: CGFloat, minimum: CGFloat, gap: CGFloat)
        case dock(sides: [ShownResizeRange.DockSide], viewport: CGFloat, gap: CGFloat, minimum: CGFloat)
        case trade(ShownResizeRange.TradeInput)
        case rows(ShownResizeRange.RowInput)
    }

    static func output(_ input: Input) -> String {
        switch input {
        case let .ratio(container, divider, a, b):
            answer(ShownResizeRange.ratioRule(containerExtent: container, dividerExtent: divider, minimumA: a, minimumB: b))
        case let .width(isColumns, isDocked, strip, minimum, gap):
            answer(ShownResizeRange.columnWidthRule(isColumns: isColumns, isDocked: isDocked, stripWidth: strip, minimumWidth: minimum, gap: gap))
        case let .dock(sides, viewport, gap, minimum):
            answer(ShownResizeRange.dockWidthRule(sides, viewportWidth: viewport, gap: gap, minimumWidth: minimum))
        case let .trade(input): answer(ShownResizeRange.tradeRule(input))
        case let .rows(input): answer(ShownResizeRange.rowHeightsRule(input))
        }
    }

    static func line(_ input: Input) -> String {
        let fields: [String]
        switch input {
        case let .ratio(container, divider, a, b): fields = ["ratio", hex(container), hex(divider), hex(a), hex(b)]
        case let .width(isColumns, isDocked, strip, minimum, gap):
            fields = ["width", flag(isColumns), flag(isDocked), hex(strip), hex(minimum), hex(gap)]
        case let .dock(sides, viewport, gap, minimum):
            let head: [String] = ["dock", hex(viewport), hex(gap), hex(minimum), "\(sides.count)"]
            let each: [String] = sides.flatMap { side -> [String] in
                [flag(side.isTarget), flag(side.isBand), flag(side.isDocked), hex(side.width)]
            }
            fields = head + each
        case let .trade(t):
            let frames: [String] = [hex(t.leftMinX), hex(t.leftMaxX), hex(t.leftWidth), hex(t.rightMinX), hex(t.rightMaxX),
                                    hex(t.rightWidth)]
            let columns: [String] = [hex(t.leftMinimumWidth), hex(t.rightMinimumWidth), hex(t.leftFraction), hex(t.rightFraction)]
            let offset: String = t.stripOffset.map { hex($0) } ?? "-"
            let strip: [String] = [offset, hex(t.uncoveredMinX), hex(t.uncoveredMaxX), hex(t.stripMinX)]
            let head: [String] = ["trade", flag(t.isColumns), hex(t.stripWidth), hex(t.gap), hex(t.scale), hex(t.delta)]
            fields = head + frames + columns + strip
        case let .rows(r):
            let count: [String] = ["rows", "\(r.heights.count)"]
            let heights: [String] = r.heights.map { "\($0)" }
            let minimums: [String] = r.minimumHeights.map { hex($0) }
            let rest: [String] = ["\(r.paneRow)", flag(r.rowsEnabled), hex(r.columnHeight), hex(r.gap), hex(r.scale), hex(r.delta)]
            fields = count + heights + minimums + rest
        }
        return fields.joined(separator: " ") + " => " + output(input)
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

        mutating func double() throws -> Double {
            let text = try word()
            let bits = try #require(UInt64(text, radix: 16), "not a float: \(text)")
            return Double(bitPattern: bits)
        }

        mutating func int() throws -> Int {
            let text = try word()
            return try #require(Int(text), "not an int: \(text)")
        }
        mutating func bool() throws -> Bool { try word() == "1" }
    }

    static func readRatio(_ f: inout Fields) throws -> ShownResizeRange.Bounds? {
        ShownResizeRange.ratioRule(containerExtent: try f.double(), dividerExtent: try f.double(), minimumA: try f.double(),
                                   minimumB: try f.double())
    }

    static func readWidth(_ f: inout Fields) throws -> ShownResizeRange.Bounds? {
        ShownResizeRange.columnWidthRule(isColumns: try f.bool(), isDocked: try f.bool(), stripWidth: try f.double(),
                                         minimumWidth: try f.double(), gap: try f.double())
    }

    static func readDock(_ f: inout Fields) throws -> ShownResizeRange.Bounds? {
        let viewport = try f.double(), gap = try f.double(), minimum = try f.double(), count = try f.int()
        var sides: [ShownResizeRange.DockSide] = []
        for _ in 0 ..< count {
            sides.append(.init(isTarget: try f.bool(), isBand: try f.bool(), isDocked: try f.bool(), width: try f.double()))
        }
        return ShownResizeRange.dockWidthRule(sides, viewportWidth: viewport, gap: gap, minimumWidth: minimum)
    }

    static func readTrade(_ f: inout Fields) throws -> ShownResizeRange.TradeCandidates? {
        let isColumns = try f.bool()
        let strip = try f.double(), gap = try f.double(), scale = try f.double(), delta = try f.double()
        let lMin = try f.double(), lMax = try f.double(), lW = try f.double()
        let rMin = try f.double(), rMax = try f.double(), rW = try f.double()
        let lMinimum = try f.double(), rMinimum = try f.double(), lFrac = try f.double(), rFrac = try f.double()
        let offsetWord = try f.word()
        let offset: CGFloat? = offsetWord == "-" ? nil : UInt64(offsetWord, radix: 16).map { CGFloat(Double(bitPattern: $0)) }
        let uMin = try f.double(), uMax = try f.double(), sMin = try f.double()
        return ShownResizeRange.tradeRule(.init(
            isColumns: isColumns, stripWidth: strip, gap: gap, scale: scale, delta: delta, leftMinX: lMin, leftMaxX: lMax,
            leftWidth: lW, rightMinX: rMin, rightMaxX: rMax, rightWidth: rW, leftMinimumWidth: lMinimum,
            rightMinimumWidth: rMinimum, leftFraction: lFrac, rightFraction: rFrac, stripOffset: offset,
            uncoveredMinX: uMin, uncoveredMaxX: uMax, stripMinX: sMin))
    }

    static func readRows(_ f: inout Fields) throws -> [Int]? {
        let count = try f.int()
        var heights: [Int] = [], minimums: [CGFloat] = []
        for _ in 0 ..< count { heights.append(try f.int()) }
        for _ in 0 ..< count { minimums.append(try f.double()) }
        return ShownResizeRange.rowHeightsRule(.init(
            heights: heights, minimumHeights: minimums, paneRow: try f.int(), rowsEnabled: try f.bool(),
            columnHeight: try f.double(), gap: try f.double(), scale: try f.double(), delta: try f.double()))
    }

    // MARK: Answers

    nonisolated static func hex(_ value: Double) -> String { String(value.bitPattern, radix: 16) }
    nonisolated static func flag(_ value: Bool) -> String { value ? "1" : "0" }

    static func answer(_ bounds: ShownResizeRange.Bounds?) -> String {
        bounds.map { "\(hex($0.lower)) \(hex($0.upper))" } ?? "-"
    }

    static func answer(_ trade: ShownResizeRange.TradeCandidates?) -> String {
        trade.map { [hex($0.move), hex($0.first.left), hex($0.first.right), hex($0.second.left), hex($0.second.right)].joined(separator: " ") }
            ?? "-"
    }

    static func answer(_ heights: [Int]?) -> String { heights.map { $0.map { "\($0)" }.joined(separator: " ") } ?? "-" }

    // MARK: The seeded corpus

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A value in `range`, often on a half or whole point (as layout values are), sometimes exact ends.
        mutating func value(_ range: ClosedRange<Double>) -> Double {
            let pick = next() % 10
            if pick == 0 { return range.lowerBound }
            if pick == 1 { return range.upperBound }
            let unit = Double(next() >> 11) / Double(1 << 53)
            let raw = range.lowerBound + (range.upperBound - range.lowerBound) * unit
            switch pick {
            case 2, 3: return raw.rounded()
            case 4, 5: return (raw * 2).rounded() / 2
            default: return raw
            }
        }

        mutating func int(_ range: ClosedRange<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
        }

        mutating func bool() -> Bool { next() & 1 == 1 }

        mutating func pick<T>(_ values: [T]) -> T { values[int(0 ... values.count - 1)] }
    }

    static func ratioInputs(_ r: inout SplitMix64) -> [Input] {
        var inputs: [Input] = [.ratio(container: 0, divider: 0, minimumA: 0, minimumB: 0),
                               .ratio(container: 1000, divider: 1, minimumA: 499.5, minimumB: 499.5),
                               .ratio(container: 1000, divider: 1, minimumA: 500, minimumB: 500)]
        for _ in 0 ..< 400 {
            inputs.append(.ratio(container: r.value(-10 ... 3000), divider: r.value(0 ... 20), minimumA: r.value(0 ... 1600),
                                 minimumB: r.value(0 ... 1600)))
        }
        return inputs
    }

    static func widthInputs(_ r: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        for _ in 0 ..< 300 {
            inputs.append(.width(isColumns: r.int(0 ... 4) > 0, isDocked: r.int(0 ... 4) == 0, strip: r.value(-50 ... 3000),
                                 minimum: r.value(0 ... 2400), gap: r.value(0 ... 40)))
        }
        return inputs
    }

    static func dockInputs(_ r: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        for _ in 0 ..< 400 {
            let count = r.int(0 ... 4)
            var sides: [ShownResizeRange.DockSide] = []
            let target = r.int(-1 ... max(0, count - 1))
            for index in 0 ..< count {
                sides.append(.init(isTarget: index == target, isBand: r.int(0 ... 3) == 0, isDocked: r.bool(),
                                   width: r.value(0 ... 1600)))
            }
            inputs.append(.dock(sides: sides, viewport: r.value(0 ... 4000), gap: r.value(0 ... 40), minimum: r.value(0 ... 1600)))
        }
        return inputs
    }

    static func tradeInputs(_ r: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        for _ in 0 ..< 1200 {
            let strip = r.value(-20 ... 4000), anyGap = r.value(0 ... 40)
            let gap = r.pick([0, 4, 6, 8, 12, anyGap])
            let scale = r.pick([0.0, 1, 1.5, 2, 2, 2, 3])
            let anyDelta = r.value(-0.6 ... 0.6), tinyDelta = r.value(-0.002 ... 0.002)
            let delta = r.pick([0, 0.05, -0.05, 0.1, -0.1, 0.025, -0.025, anyDelta, tinyDelta])
            let leftMinX = r.value(-500 ... 3000), leftWidth = r.value(0 ... 2200)
            let leftMaxX = r.int(0 ... 9) == 0 ? r.value(-500 ... 5000) : leftMinX + leftWidth
            let rightMinX = r.int(0 ... 9) == 0 ? r.value(-500 ... 5000) : leftMaxX + gap
            let rightWidth = r.value(0 ... 2200)
            let rightMaxX = r.int(0 ... 9) == 0 ? r.value(-500 ... 7000) : rightMinX + rightWidth
            let anyOffset = CGFloat(r.value(-200 ... 3000))
            let offset: CGFloat? = r.int(0 ... 2) == 0 ? nil : anyOffset
            let stripMinX = r.value(0 ... 600)
            inputs.append(.trade(.init(
                isColumns: r.int(0 ... 9) > 0, stripWidth: strip, gap: gap, scale: scale, delta: delta,
                leftMinX: leftMinX, leftMaxX: leftMaxX, leftWidth: leftWidth,
                rightMinX: rightMinX, rightMaxX: rightMaxX, rightWidth: rightWidth,
                leftMinimumWidth: r.value(0 ... 1600), rightMinimumWidth: r.value(0 ... 1600),
                leftFraction: r.value(0 ... 1.2), rightFraction: r.value(0 ... 1.2), stripOffset: offset,
                uncoveredMinX: stripMinX + r.value(-50 ... 400), uncoveredMaxX: stripMinX + strip - r.value(-50 ... 400),
                stripMinX: stripMinX)))
        }
        return inputs
    }

    static func rowInputs(_ r: inout SplitMix64) -> [Input] {
        var inputs: [Input] = []
        for _ in 0 ..< 900 {
            let count = r.int(1 ... 5)
            var heights: [Int] = [], minimums: [CGFloat] = []
            for _ in 0 ..< count {
                let wide = r.int(1 ... 1200), middle = r.int(100 ... 600)
                heights.append(r.pick([wide, middle, 0, -5, 100, 1000, 333, 334]))
            }
            for _ in 0 ..< count { minimums.append(r.value(0 ... 700)) }
            let paneRow = r.int(0 ... count - 1), rowsEnabled = r.bool(), columnHeight = r.value(1 ... 2000)
            let anyGap = r.value(0 ... 24)
            let gap = r.pick([0, 4, 8, anyGap])
            let scale = r.pick([0.0, 1, 2, 2, 3])
            let anyDelta = r.value(-0.6 ... 0.6), tinyDelta = r.value(-0.003 ... 0.003)
            let delta = r.pick([0, 0.05, -0.05, 0.1, -0.1, anyDelta, tinyDelta])
            inputs.append(.rows(.init(
                heights: heights, minimumHeights: minimums, paneRow: paneRow, rowsEnabled: rowsEnabled,
                columnHeight: columnHeight, gap: gap, scale: scale, delta: delta)))
        }
        return inputs
    }
}
