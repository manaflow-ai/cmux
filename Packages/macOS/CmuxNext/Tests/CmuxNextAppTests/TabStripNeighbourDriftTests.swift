import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo (ask-b513dbd9ed, "tab-open jank"): "this details moves aroud". Per animation frame, what the Mac tab strip moves
/// that should hold still: for an open (a roomy strip, a squeezed one, a crowded one at the minimum width, with and
/// without the new tab selected), a close (keyboard, and a mouse close in closing mode), a selection (in view, and one
/// that scrolls), a reorder and closing mode's release, every neighbour tab's leading edge and width, the + and the
/// pane's trailing tools are read every 120 Hz tick from the change's begin to one tick past its end.
///
/// What has no reason to move must stay within 1 px of where it was before the change in every tick; what is meant to
/// move must go one way, from where it was to where it rests: no jump at the begin, no step back, nothing past the rest.
/// A case that drifts is a finding: it is listed in ``knownDrifts`` (a known issue, so the suite stays green and turns
/// red when the drift is fixed) and its number goes in the drift table. Every anchor prints one `neighbour-drift:` line
/// with its numbers, which is where the table's numbers come from.
///
/// The seam is `TabCloseMotionTests`': the strip lives in pane content in no window (`Motion.canAnimate` lets it animate),
/// and each tick is read from the layers' animations at begin plus k/120 s (`MotionPath`, the render server's own
/// evaluation), not at real time.
@MainActor @Suite(.serialized) struct TabStripNeighbourDriftTests {
    /// Anchors this suite measured drifting (`case.anchor.check`): each runs as a known issue.
    static let knownDrifts: Set<String> = []

    struct Rig {
        let model: TabStripModel
        let pane: PaneContentView
        let toolbar: PaneToolbar
        var strip: TabStripView { pane.stripView }
    }

    /// A 900 pt pane with `count` tabs and the pane's trailing tools, `selected` selected. A close intent drops the tab
    /// from the model at once, as `PaneController.close` does; the strip catches up on its next sync.
    static func rig(count: Int, selected: Int = 0) -> Rig {
        let reveal = LaunchReveal()
        reveal.markAllReady()
        let model = TabStripModel(tabs: TabCloseMotionTests.tabs(count), selectedID: TabID("tab\(selected)"))
        let pane = PaneContentView(stripModel: model, reveal: reveal)
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry })
        pane.toolbar = toolbar
        toolbar.update(target: "tab\(selected)", kind: .terminal, paneKinds: [.terminal])
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        model.intentHandler = { [weak model] intent in
            if case .close(let id, _) = intent { model?.tabs.removeAll { $0.id == id } }
        }
        pane.stripView.sync(fromModel: true)
        pane.layoutSubtreeIfNeeded()
        return Rig(model: model, pane: pane, toolbar: toolbar)
    }

    /// How many tabs make each strip, from the pane's viewport and the tab metrics.
    struct Counts {
        /// Every tab at the maximum width, with room for one more at it.
        let roomy: Int
        /// The tabs share the strip under the maximum width and over the minimum, also with one more or one fewer.
        let squeezed: Int
        /// The tabs are at the minimum width and the strip scrolls.
        let crowded: Int
    }

    static func counts() -> Counts {
        let probe = rig(count: 2)
        let viewport = probe.strip.viewportWidth, metrics = probe.strip.metrics
        let roomy = max(1, Int(viewport / (metrics.maxTabWidth + 8)) - 1)
        let squeezed = Int(viewport / metrics.maxTabWidth) + 2
        let crowded = Int(viewport / max(1, metrics.minInactiveTabWidth)) + 6
        return Counts(roomy: roomy, squeezed: squeezed, crowded: crowded)
    }

    // MARK: - Anchors

    /// One thing the strip shows, read at a media time.
    enum Anchor: Hashable, CustomStringConvertible {
        case x(Int), width(Int), gap(Int, Int), plus, tools, stripEnd

        var description: String {
            switch self {
            case .x(let i): "x(tab\(i))"
            case .width(let i): "width(tab\(i))"
            case .gap(let l, let r): "gap(tab\(l)|tab\(r))"
            case .plus: "plus"
            case .tools: "tools"
            case .stripEnd: "stripEnd"
            }
        }
    }

    /// A layer's shown left edge and width: its model geometry plus every move on it, as the render server draws it.
    struct Shown {
        let position: MotionPath
        let size: MotionPath
        let anchor: CGPoint

        init(_ layer: CALayer) {
            position = MotionPath(layer, "position")
            size = MotionPath(layer, "bounds.size")
            anchor = layer.anchorPoint
        }

        func width(_ time: CFTimeInterval) -> CGFloat { size.value(at: time).x }
        func minX(_ time: CFTimeInterval) -> CGFloat { position.value(at: time).x - anchor.x * width(time) }
        var end: CFTimeInterval? { [position.end, size.end].compactMap { $0 }.max() }
    }

    /// Reads `anchor` on the strip as its layers are now (nil: the tab has no cell yet).
    static func reader(_ rig: Rig, _ anchor: Anchor) -> ((CFTimeInterval) -> CGFloat)? {
        func cell(_ i: Int) -> Shown? { rig.strip.cells[TabID("tab\(i)")].map { Shown($0.layer) } }
        switch anchor {
        case .x(let i):
            guard let shown = cell(i) else { return nil }
            return { shown.minX($0) }
        case .width(let i):
            guard let shown = cell(i) else { return nil }
            return { shown.width($0) }
        case .gap(let l, let r):
            guard let left = cell(l), let right = cell(r) else { return nil }
            return { right.minX($0) - (left.minX($0) + left.width($0)) }
        case .plus:
            guard let layer = rig.strip.newTabButton.layer else { return nil }
            let shown = Shown(layer)
            return { shown.minX($0) }
        case .tools:
            let view = rig.toolbar.view, frame = view.frame
            guard let layer = view.layer else { return { _ in frame.minX } }
            let shown = Shown(layer)
            return { shown.minX($0) }
        case .stripEnd:
            let end = rig.strip.frame.maxX
            return { _ in end }
        }
    }

    /// Every frame of one anchor: before the change, each tick from the move's begin, and at rest.
    struct Series {
        let before: CGFloat
        let samples: [CGFloat]
        let rest: CGFloat

        /// The furthest any tick got from where it was before the change.
        var drift: CGFloat { (samples + [rest]).map { abs($0 - before) }.max() ?? 0 }
        /// How far the first tick is from where it was before the change.
        var jump: CGFloat { abs((samples.first ?? before) - before) }
        var travel: CGFloat { rest - before }
        /// How far a tick went past where it rests, in the direction of travel.
        var overshoot: CGFloat {
            guard abs(travel) > 0.5 else { return 0 }
            let direction: CGFloat = travel > 0 ? 1 : -1
            return max(0, samples.map { direction * ($0 - rest) }.max() ?? 0)
        }
        /// The largest step back against the direction of travel between two ticks.
        var back: CGFloat {
            guard abs(travel) > 0.5 else { return 0 }
            let direction: CGFloat = travel > 0 ? 1 : -1
            return zip(samples, samples.dropFirst()).map { max(0, -direction * ($1 - $0)) }.max() ?? 0
        }
    }

    struct Measured {
        let series: [Anchor: Series]
        let moved: Bool
        let ticks: Int
    }

    /// Reads `anchors` before `change`, then each tick of the strip move it starts (every tab, the + and its chooser),
    /// from the earliest begin to one tick past the latest end, and once more a second after that (at rest).
    static func measure(_ rig: Rig, _ anchors: [Anchor], _ change: () throws -> Void) throws -> Measured {
        try #require(TabCloseMotionTests.moveKeys(rig.strip).isEmpty, "SETUP: a strip move runs before the change")
        let now = CACurrentMediaTime()
        let before = Dictionary(uniqueKeysWithValues: anchors.compactMap { anchor in reader(rig, anchor).map { (anchor, $0(now)) } })
        try change()
        rig.pane.layoutSubtreeIfNeeded()
        let strip = rig.strip
        let layers = strip.cells.values.map(\.layer) + [strip.newTabButton.layer, strip.newTabMenuButton.layer].compactMap { $0 }
        let begins = layers.flatMap { layer in
            (layer.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) }.compactMap { key in
                layer.animation(forKey: key).map { layer.convertTime($0.beginTime, to: nil) }
            }
        }
        let begin = begins.min() ?? CACurrentMediaTime()
        let end = max(begin, layers.compactMap { Shown($0).end }.max() ?? begin)
        // At least 200 ms of ticks, so a change that moves nothing is still read over a tween's length.
        let ticks = max(24, Int(((end - begin) * 120).rounded(.up)) + 1)
        var series: [Anchor: Series] = [:]
        for anchor in anchors {
            let read = try #require(reader(rig, anchor), "\(anchor) has nothing to read after the change")
            let samples = (0...ticks).map { read(begin + Double($0) / 120) }
            series[anchor] = Series(before: before[anchor] ?? samples[0], samples: samples, rest: read(end + 1))
        }
        return Measured(series: series, moved: !begins.isEmpty, ticks: ticks)
    }

    /// Prints every anchor's numbers and checks them: `holds` within 1 px of where it was in every tick, `moves` one way
    /// from where it was to its rest. A check listed in ``knownDrifts`` runs as a known issue.
    static func verdict(_ name: String, _ measured: Measured, holds: [Anchor], moves: [Anchor]) {
        func fmt(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
        for (role, list) in [("holds", holds), ("moves", moves)] {
            for anchor in list {
                guard let s = measured.series[anchor] else { continue }
                print("neighbour-drift: case=\(name) anchor=\(anchor) role=\(role) before=\(fmt(s.before)) rest=\(fmt(s.rest))"
                    + " drift=\(fmt(s.drift)) jump=\(fmt(s.jump)) overshoot=\(fmt(s.overshoot)) back=\(fmt(s.back)) ticks=\(measured.ticks)")
            }
        }
        let held = holds.compactMap { measured.series[$0]?.drift }.max() ?? 0
        print("neighbour-drift: case=\(name) summary holdsMaxDrift=\(fmt(held)) moved=\(measured.moved)")
        func check(_ key: String, _ ok: Bool, _ message: String) {
            let full = "\(name).\(key)"
            if knownDrifts.contains(full) {
                withKnownIssue(Comment(rawValue: "measured drift \(full): \(message)")) { #expect(ok, "\(full): \(message)") }
            } else {
                #expect(ok, "\(full): \(message)")
            }
        }
        for anchor in holds {
            guard let s = measured.series[anchor] else { continue }
            check("\(anchor).holds", s.drift <= 1, "moved \(fmt(s.drift)) px from \(fmt(s.before)) (rest \(fmt(s.rest)))")
        }
        for anchor in moves {
            guard let s = measured.series[anchor] else { continue }
            check("\(anchor).jump", s.jump < 0.5, "jumped \(fmt(s.jump)) px at the move's begin")
            check("\(anchor).overshoot", s.overshoot < 0.5, "went \(fmt(s.overshoot)) px past its rest \(fmt(s.rest))")
            check("\(anchor).back", s.back < 0.25, "stepped back \(fmt(s.back)) px against its travel \(fmt(s.travel))")
        }
    }

    /// Reduce Motion off, the new-tab growth on (`TabCloseMotionTests.withMotion`), overflow `.shrink`; restores both.
    static func run(_ body: () throws -> Void) throws {
        let overflow = DesignSettings.shared.tabOverflow
        DesignSettings.shared.tabOverflow = .shrink
        defer { DesignSettings.shared.tabOverflow = overflow }
        try TabCloseMotionTests.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            try body()
        }
    }

    static func xs(_ range: some Sequence<Int>) -> [Anchor] { range.map { .x($0) } }
    static func widths(_ range: some Sequence<Int>) -> [Anchor] { range.map { .width($0) } }
    static func gaps(_ range: ClosedRange<Int>) -> [Anchor] { zip(range, range.dropFirst()).map { .gap($0, $1) } }

    /// The tabs the strip shows in the viewport (the crowded cases read these, not the ones scrolled away).
    static func inView(_ rig: Rig) -> [Int] {
        let viewport = rig.strip.viewportWidth
        return rig.model.tabs.indices.filter { i in
            guard let slot = rig.strip.result.slot(TabID("tab\(i)")) else { return false }
            return slot.x < viewport
        }
    }

    // MARK: - Open

    /// A roomy strip: a tab opens at the end. Every tab left of it holds its edge and width; the + slides right.
    @Test func openInARoomyStrip() throws {
        try Self.run {
            let n = Self.counts().roomy
            let rig = Self.rig(count: n)
            try #require(!rig.strip.result.isOverflowing && rig.strip.result.standardWidth >= rig.strip.metrics.maxTabWidth - 0.5,
                         "SETUP: \(n) tabs are not at the maximum width")
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd, .width(n)]) {
                rig.model.tabs.append(TabItem(id: TabID("tab\(n)"), title: "Tab \(n)"))
                rig.model.selectedID = TabID("tab\(n)")
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the open started no strip move")
            try #require(rig.strip.result.standardWidth >= rig.strip.metrics.maxTabWidth - 0.5, "SETUP: the open squeezed the strip")
            Self.verdict("openRoomy", measured, holds: Self.xs(0..<n) + Self.widths(0..<n) + [.tools, .stripEnd],
                         moves: [.plus, .width(n)])
        }
    }

    /// A squeezed strip: a tab opens at the end and every tab narrows. The first tab's leading edge, the + (held at the
    /// strip's end) and the tools hold; the other edges and every width go one way.
    @Test func openInASqueezedStrip() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            let result = rig.strip.result
            try #require(!result.isOverflowing && result.standardWidth < rig.strip.metrics.maxTabWidth - 0.5,
                         "SETUP: \(n) tabs do not share the strip under the maximum width")
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0...n) + [.plus, .tools, .stripEnd]) {
                rig.model.tabs.append(TabItem(id: TabID("tab\(n)"), title: "Tab \(n)"))
                rig.model.selectedID = TabID("tab\(n)")
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the open started no strip move")
            Self.verdict("openSqueezed", measured, holds: [.x(0), .plus, .tools, .stripEnd],
                         moves: Self.xs(1..<n) + Self.widths(0...n))
        }
    }

    /// A crowded strip, tabs at the minimum width: a tab opens at the end, off screen, the selection stays on the first
    /// tab. No tab in view, no + and no tool moves.
    @Test func openInACrowdedStripKeepingTheSelection() throws {
        try Self.run {
            let n = Self.counts().crowded
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.isOverflowing, "SETUP: \(n) tabs do not overflow the strip")
            let shown = Self.inView(rig)
            let measured = try Self.measure(rig, Self.xs(shown) + Self.widths(shown) + [.plus, .tools, .stripEnd]) {
                rig.model.tabs.append(TabItem(id: TabID("tab\(n)"), title: "Tab \(n)"))
                rig.strip.sync(fromModel: true)
            }
            Self.verdict("openCrowded", measured, holds: Self.xs(shown) + Self.widths(shown) + [.plus, .tools, .stripEnd], moves: [])
        }
    }

    /// A crowded strip: a tab opens at the end and is selected (Cmd-T), so the strip scrolls to it. Every tab moves by the
    /// scroll alone: the gaps between neighbours, their widths, the + and the tools hold, and each edge goes one way.
    @Test func openInACrowdedStripSelectingTheNewTab() throws {
        try Self.run {
            let n = Self.counts().crowded
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.isOverflowing, "SETUP: \(n) tabs do not overflow the strip")
            let tail = (n - 8)...(n - 1)
            let measured = try Self.measure(rig, Self.xs(tail) + Self.widths(tail) + Self.gaps(tail) + [.plus, .tools, .stripEnd]) {
                rig.model.tabs.append(TabItem(id: TabID("tab\(n)"), title: "Tab \(n)"))
                rig.model.selectedID = TabID("tab\(n)")
                rig.toolbar.update(target: "tab\(n)", kind: .terminal, paneKinds: [.terminal])
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the open started no strip move")
            Self.verdict("openCrowdedSelected", measured, holds: Self.widths(tail) + Self.gaps(tail) + [.plus, .tools, .stripEnd],
                         moves: Self.xs(tail))
        }
    }

    // MARK: - Close

    /// A roomy strip: Cmd-W on the middle tab. The tab left of it holds; the one right of it slides left with the +.
    @Test func keyboardCloseInARoomyStrip() throws {
        try Self.run {
            let n = max(3, Self.counts().roomy + 1)
            let rig = Self.rig(count: n)
            try #require(!rig.strip.result.isOverflowing && rig.strip.result.standardWidth >= rig.strip.metrics.maxTabWidth - 0.5,
                         "SETUP: \(n) tabs are not at the maximum width")
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]) {
                rig.strip.close(TabID("tab1"), source: .keyboard)
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the close started no strip move")
            Self.verdict("closeKeyboardRoomy", measured, holds: [.x(0), .width(0)] + Self.widths(2..<n) + [.tools, .stripEnd],
                         moves: Self.xs(2..<n) + [.plus, .width(1)])
        }
    }

    /// A squeezed strip: Cmd-W on the second tab, every tab widens. The first tab's leading edge, the + and the tools hold.
    @Test func keyboardCloseInASqueezedStrip() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.standardWidth < rig.strip.metrics.maxTabWidth - 0.5, "SETUP: the strip is not squeezed")
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]) {
                rig.strip.close(TabID("tab1"), source: .keyboard)
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the close started no strip move")
            Self.verdict("closeKeyboardSqueezed", measured, holds: [.x(0), .plus, .tools, .stripEnd],
                         moves: Self.xs(2..<n) + Self.widths(0..<n))
        }
    }

    /// A squeezed strip: a mouse close of the second tab, closing mode (Chrome): every tab keeps its width, the first holds
    /// still, the tabs right of the closed one and the + slide left into its room.
    @Test func mouseCloseInClosingMode() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.standardWidth < rig.strip.metrics.maxTabWidth - 0.5, "SETUP: the strip is not squeezed")
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]) {
                rig.strip.close(TabID("tab1"), source: .mouse)
                rig.strip.sync(fromModel: true)
            }
            try #require(rig.strip.closingModeWidth != nil, "the mouse close did not enter closing mode")
            try #require(measured.moved, "the close started no strip move")
            Self.verdict("closeMouseClosingMode", measured, holds: [.x(0), .width(0)] + Self.widths(2..<n) + [.tools, .stripEnd],
                         moves: Self.xs(2..<n) + [.plus, .width(1)])
        }
    }

    /// Closing mode ends (the pointer left the strip, `TabClosingModeWatch.exit`): the tabs widen on the close tween. The
    /// first tab's leading edge and the tools hold; every width, every other edge and the + go one way.
    @Test func closingModeRelease() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.standardWidth < rig.strip.metrics.maxTabWidth - 0.5, "SETUP: the strip is not squeezed")
            // The close lands at once (no move), so the strip rests in closing mode with the widths held.
            rig.strip.close(TabID("tab1"), source: .mouse)
            rig.strip.sync(fromModel: true, animating: false)
            rig.pane.layoutSubtreeIfNeeded()
            try #require(rig.strip.closingModeWidth != nil, "SETUP: the mouse close did not enter closing mode")
            let kept = [0] + Array(2..<n)
            let measured = try Self.measure(rig, Self.xs(kept) + Self.widths(kept) + [.plus, .tools, .stripEnd]) {
                rig.strip.closingWatch.exit()
            }
            try #require(rig.strip.closingModeWidth == nil, "closing mode did not end")
            try #require(measured.moved, "the release started no strip move")
            Self.verdict("closingModeRelease", measured, holds: [.x(0), .tools, .stripEnd],
                         moves: Self.xs(2..<n) + Self.widths(kept) + [.plus])
        }
    }

    // MARK: - Select

    /// A squeezed strip: selecting a tab in view moves nothing at all.
    @Test func selectingATabInView() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            let all = Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]
            let measured = try Self.measure(rig, all) {
                rig.model.selectedID = TabID("tab\(n - 2)")
                rig.toolbar.update(target: "tab\(n - 2)", kind: .terminal, paneKinds: [.terminal])
                rig.strip.syncFromModel()
            }
            #expect(!measured.moved, "selecting a tab in view started a strip move")
            Self.verdict("selectInView", measured, holds: all, moves: [])
        }
    }

    /// A crowded strip: selecting the last tab, scrolled away, reveals it. Every tab moves by the scroll alone: widths,
    /// gaps, the + and the tools hold, each edge goes one way (the reveal's spring must not pass its rest).
    @Test func selectingATabScrolledAway() throws {
        try Self.run {
            let n = Self.counts().crowded
            let rig = Self.rig(count: n)
            try #require(rig.strip.result.isOverflowing, "SETUP: \(n) tabs do not overflow the strip")
            let tail = (n - 8)...(n - 1)
            let measured = try Self.measure(rig, Self.xs(tail) + Self.widths(tail) + Self.gaps(tail) + [.plus, .tools, .stripEnd]) {
                rig.model.selectedID = TabID("tab\(n - 1)")
                rig.toolbar.update(target: "tab\(n - 1)", kind: .terminal, paneKinds: [.terminal])
                rig.strip.syncFromModel()
            }
            try #require(measured.moved, "the reveal started no strip move")
            Self.verdict("selectReveal", measured, holds: Self.widths(tail) + Self.gaps(tail) + [.plus, .tools, .stripEnd],
                         moves: Self.xs(tail))
        }
    }

    // MARK: - Reorder

    /// A squeezed strip: the second and third tabs swap (a move-left key). The others, every width, the + and the tools
    /// hold; the two swapped edges go one way.
    @Test func reorderSwapsTwoNeighbours() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]) {
                rig.model.tabs.swapAt(1, 2)
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the reorder started no strip move")
            Self.verdict("reorderSwap", measured, holds: [.x(0)] + Self.xs(3..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd],
                         moves: [.x(1), .x(2)])
        }
    }

    /// A squeezed strip: the first tab moves to the end. Every width, the + and the tools hold; every edge goes one way.
    @Test func reorderFirstToLast() throws {
        try Self.run {
            let n = Self.counts().squeezed
            let rig = Self.rig(count: n)
            let measured = try Self.measure(rig, Self.xs(0..<n) + Self.widths(0..<n) + [.plus, .tools, .stripEnd]) {
                let first = rig.model.tabs.removeFirst()
                rig.model.tabs.append(first)
                rig.strip.sync(fromModel: true)
            }
            try #require(measured.moved, "the reorder started no strip move")
            Self.verdict("reorderFirstToLast", measured, holds: Self.widths(0..<n) + [.plus, .tools, .stripEnd], moves: Self.xs(0..<n))
        }
    }
}
