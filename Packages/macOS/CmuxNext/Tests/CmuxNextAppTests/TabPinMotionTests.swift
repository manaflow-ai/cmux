import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Lawrence 2026-11-08 (cmux-ad m70): "animation when i pin stuff and unpin stuff is not very good. like it needs to
/// translate properly from its original position to new position". A tab pin or unpin moves the SAME cell (Chromium's
/// `TabStripLayoutHelper` + `BoundsAnimator`) from where it shows to its new slot on the strip's one tween: the title
/// and the icon change on the width's progress (no pop on the first frame), the cell is never clipped by the pinned
/// band's edge, the tabs it passes keep their order with no overlap, and the pinned divider never draws over the
/// moving tab and never pops. Each 120 Hz frame is sampled at a fixed media time (`MotionPath`), as
/// `TabMoveMotionTargetTests` does; the strip animates only on a screen, so these need a display worker.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct TabPinMotionTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// Six tabs, tab0 pinned, tab3 selected (the film's fixture); `pin`: tab3 pins, else (tab3 pinned first) it unpins.
    @Test(.enabled("the strip animates only in a window on a screen") { await Self.hasDisplay() })
    func aPinnedTabMovesToItsPinnedSlot() throws { try Self.check(pin: true) }

    @Test(.enabled("the strip animates only in a window on a screen") { await Self.hasDisplay() })
    func anUnpinnedTabMovesBackOutOfThePinnedGroup() throws { try Self.check(pin: false) }

    /// Reduce Motion: the pin is final at once, with no move on any cell or the divider.
    @Test(.enabled("the strip animates only in a window on a screen") { await Self.hasDisplay() })
    func withoutMotionAPinIsFinalAtOnce() throws {
        let (strip, model, window) = try Self.strip(pinned: [Self.ids[0]])
        defer { window.closeAfterTest() }
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        model.tabs = Self.tabs(pinned: [Self.ids[0], Self.moved])
        strip.sync(fromModel: true)
        let layers = strip.cells.values.flatMap { [$0.layer] + ($0.layer.sublayers ?? []) } + [strip.pinnedDivider, strip.scrollingLayer]
        let moving = layers.filter { !($0.animationKeys() ?? []).filter { $0.hasPrefix(TabStripMove.keyPrefix) || $0.hasPrefix(TabCell.innerKeyPrefix) }.isEmpty }
        #expect(moving.isEmpty, "\(moving.count) layers still move with motion off")
    }

    // MARK: - The rig

    static let ids = (0..<6).map { TabID("tab\($0)") }
    static let moved = ids[3]

    static func tabs(pinned: [TabID]) -> [TabItem] {
        let pinnedTabs = pinned.compactMap { id in ids.firstIndex(of: id).map { TabItem(id: id, title: "Tab number \($0)", isPinned: true) } }
        let rest = ids.enumerated().filter { !pinned.contains($0.element) }.map { TabItem(id: $0.element, title: "Tab number \($0.offset)") }
        return pinnedTabs + rest
    }

    static func strip(pinned: [TabID]) throws -> (TabStripView, TabStripModel, NSWindow) {
        let model = TabStripModel(tabs: tabs(pinned: pinned), selectedID: moved)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 900, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let strip = TabStripView(model: model)
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView = strip
        window.orderFrontRegardless()
        try #require(window.screen != nil, "SETUP: the strip's window is on no screen")
        strip.layoutSubtreeIfNeeded()
        return (strip, model, window)
    }

    /// A layer's opacity at media time `time`: its model value with each basic or keyframe opacity animation on it.
    static func opacity(_ layer: CALayer, at time: CFTimeInterval) -> Float {
        var value = layer.opacity
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CAPropertyAnimation, animation.keyPath == "opacity" else { continue }
            let begin = layer.convertTime(animation.beginTime, to: nil)
            let duration = max(animation.duration, .ulpOfOne)
            let holdsBefore = animation.fillMode == .backwards || animation.fillMode == .both
            let holdsAfter = animation.fillMode == .forwards || animation.fillMode == .both
            guard time >= begin || holdsBefore, time < begin + duration || holdsAfter else { continue }
            let t = min(max((time - begin) / duration, 0), 1)
            var sample: Float
            if let basic = animation as? CABasicAnimation {
                let from = (basic.fromValue as? NSNumber)?.floatValue ?? layer.opacity
                let to = (basic.toValue as? NSNumber)?.floatValue ?? layer.opacity
                sample = from + (to - from) * Float(t)
            } else if let frames = animation as? CAKeyframeAnimation, let values = frames.values as? [NSNumber], !values.isEmpty {
                let times = frames.keyTimes?.map { $0.doubleValue } ?? values.indices.map { Double($0) / Double(max(1, values.count - 1)) }
                let index = max(0, (times.lastIndex { $0 <= t }) ?? 0)
                if frames.calculationMode == .discrete || index >= values.count - 1 {
                    sample = values[min(index, values.count - 1)].floatValue
                } else {
                    let span = max(times[index + 1] - times[index], .ulpOfOne)
                    let f = Float((t - times[index]) / span)
                    sample = values[index].floatValue + (values[index + 1].floatValue - values[index].floatValue) * f
                }
            } else { continue }
            value = animation.isAdditive ? value + sample : sample
        }
        return value
    }

    /// The cell's shown frame in the tabs' coordinates at `time` (its region's layer shares them).
    static func shown(_ cell: TabCell, at time: CFTimeInterval) -> CGRect {
        let layer = cell.layer
        let position = MotionPath(layer, "position").value(at: time)
        let size = MotionPath(layer, "bounds.size").value(at: time)
        return CGRect(x: position.x - layer.anchorPoint.x * size.x, y: 0, width: size.x, height: size.y)
    }

    static func check(pin: Bool) throws {
        let first = ids[0]
        let (strip, model, window) = try strip(pinned: pin ? [first] : [first, moved])
        defer { window.closeAfterTest() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
        let cell = try #require(strip.cells[moved])
        let before = CACurrentMediaTime()
        let start = shown(cell, at: before)
        let startTitle = opacity(cell.titleLayer, at: before)
        let starts = Dictionary(uniqueKeysWithValues: strip.cells.map { ($0.key, shown($0.value, at: before)) })
        model.tabs = tabs(pinned: pin ? [first, moved] : [first])
        strip.sync(fromModel: true)
        #expect(strip.cells[moved] === cell, "the tab's cell was replaced: the same view must move")
        // Frame 0 is the move's begin (`TabStripMove.begin`), not the clock after `sync` returns: a slow host's sync
        // time would otherwise read as a jump.
        let begin = try #require(TabMoveMotionTargetTests.moveBegin(Array(strip.cells.values)), "the pin did not animate")
        let ends = Dictionary(uniqueKeysWithValues: strip.cells.map { ($0.key, $0.value.layer.frame) })
        let end = ends[moved] ?? cell.layer.frame
        let endTitle = cell.titleLayer.opacity
        let ticks = MotionPath.sampleCount(seconds: 0.4)
        var failures: [String] = []
        var path: [CGRect] = []
        var titles: [Float] = []
        var icons: [CGFloat] = []
        for k in 0...ticks {
            let time = begin + Double(k) / 120
            let frame = shown(cell, at: time)
            path.append(frame)
            titles.append(opacity(cell.titleLayer, at: time))
            icons.append(frame.minX + MotionPath(cell.iconLayer, "position").value(at: time).x)
            // Never clipped by the pinned band's edge: the unpinned tabs' layer clips at it.
            for (id, other) in strip.cells {
                let shownFrame = shown(other, at: time)
                if other.layer.superlayer === strip.scrollingLayer, strip.scrollingLayer.masksToBounds {
                    let lost = max(0, strip.scrollingLayer.frame.minX - shownFrame.minX)
                    if lost > 0.5 { failures.append("tick \(k): \(id.rawValue) is cut \(lost) pt by the pinned band's edge"); break }
                }
            }
            // The tabs it passes keep their order and never overlap one another.
            let others = strip.cells.filter { $0.key != moved }.map { shown($0.value, at: time) }.sorted { $0.minX < $1.minX }
            for (a, b) in zip(others, others.dropFirst()) where b.minX < a.maxX - 0.5 {
                failures.append("tick \(k): two tabs overlap by \(a.maxX - b.minX) pt")
                break
            }
            // The divider never draws over the moving tab.
            let divider = strip.pinnedDivider
            if !divider.isHidden, opacity(divider, at: time) > 0.05 {
                let x = MotionPath(divider, "position").value(at: time).x
                if x > frame.minX + 0.5, x < frame.maxX - 0.5 { failures.append("tick \(k): the divider at \(x) draws over the moving tab \(frame)") }
            }
        }
        func far(_ a: CGRect, _ b: CGRect) -> CGFloat { max(abs(a.minX - b.minX), abs(a.width - b.width)) }
        if far(path[0], start) > 0.5 { failures.append("tick 0 jumps: \(path[0]) was \(start)") }
        if far(path[path.count - 1], end) > 0.5 { failures.append("it ends at \(path[path.count - 1]), its slot is \(end)") }
        // Monotone, no overshoot: the moving tab and every other tab.
        func monotone(_ name: String, _ xs: [CGFloat], to target: CGFloat) {
            guard let from = xs.first, abs(target - from) > 0.5 else { return }
            let sign: CGFloat = target > from ? 1 : -1
            let overshoot = xs.map { ($0 - target) * sign }.max() ?? 0
            let back = zip(xs, xs.dropFirst()).map { ($0 - $1) * sign }.max() ?? 0
            if overshoot > 0.5 { failures.append("\(name) passes its slot by \(overshoot) pt") }
            if back > 0.25 { failures.append("\(name) goes back \(back) pt") }
        }
        monotone("the moving tab", path.map(\.minX), to: end.minX)
        for (id, other) in strip.cells where id != moved {
            guard let target = ends[id], starts[id] != nil else { continue }
            monotone(id.rawValue, (0...ticks).map { shown(other, at: begin + Double($0) / 120).minX }, to: target.minX)
        }
        // The look changes on the width's progress: no step larger than the width's own step allows.
        let widths = path.map(\.width)
        let widthChange = abs(end.width - start.width)
        if widthChange > 1 {
            let progressSteps = zip(widths, widths.dropFirst()).map { abs($1 - $0) / widthChange }
            let largest = progressSteps.max() ?? 0
            if abs(endTitle - startTitle) > 0.5 {
                for (index, pair) in zip(titles, titles.dropFirst()).enumerated() where abs(pair.1 - pair.0) > Float(largest) + 0.05 {
                    failures.append("tick \(index + 1): the title's opacity steps \(pair.0) to \(pair.1), the width's largest step is \(largest)")
                    break
                }
            }
            let iconTravel = abs((icons.last ?? 0) - (icons.first ?? 0))
            for (index, pair) in zip(icons, icons.dropFirst()).enumerated()
                where abs(pair.1 - pair.0) > max(abs(path[index + 1].minX - path[index].minX), 0) + CGFloat(largest) * max(iconTravel, widthChange) + 0.75 {
                failures.append("tick \(index + 1): the icon jumps \(pair.1 - pair.0) pt")
                break
            }
        }
        // The divider fades, never pops: its opacity steps no more than the move's own step allows.
        let dividerOpacity = (0...ticks).map { strip.pinnedDivider.isHidden ? 0 : opacity(strip.pinnedDivider, at: begin + Double($0) / 120) }
        for (index, pair) in zip(dividerOpacity, dividerOpacity.dropFirst()).enumerated() where abs(pair.1 - pair.0) > 0.5 {
            failures.append("tick \(index + 1): the divider pops (\(pair.0) to \(pair.1))")
            break
        }
        #expect(failures.isEmpty, "\(pin ? "pin" : "unpin"): \(failures.prefix(16).joined(separator: "\n"))")
    }
}
