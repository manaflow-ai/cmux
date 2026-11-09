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

    /// The curve starts on the first frame that can show the pin (Chrome: an animation starts at the time of the first
    /// frame that ticks it), not at the key turn. That frame (tick 0) shows the old frame and the next one curve(1
    /// refresh), also when the key turn crosses a refresh. The K12 film at cb761d6 (cmux21, 120 Hz): the curve began at
    /// the key turn and the first moved frame showed curve(2.6 refreshes), 82.5 pt in one step.
    @Test(.enabled("the strip animates only in a window on a screen") { await hasDisplay() })
    func aPinsCurveStartsOnTheFirstFrameThatCanShowIt() throws {
        let first = Self.ids[0]
        let (strip, model, window) = try Self.strip(pinned: [first])
        defer { window.closeAfterTest() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let refresh = 1.0 / 120
        // A vsync at `grid`; the key turn writes the frames 1.3 refreshes after it (it crossed a refresh), so the first
        // frame that can show the pin begins at the vsync after that, 2 refreshes after `grid`.
        let grid = CACurrentMediaTime()
        strip.frameClock = MotionFrameClock(now: { grid + 1.3 * refresh }, vsync: { (grid, refresh) }, refresh: { refresh })
        let firstFrame = grid + 2 * refresh
        let cell = try #require(strip.cells[Self.moved])
        let start = Self.shown(cell, at: grid)
        model.tabs = Self.tabs(pinned: [first, Self.moved])
        strip.sync(fromModel: true)
        let end = cell.layer.frame
        let begin = try #require(TabMoveMotionTargetTests.moveBegin(Array(strip.cells.values)), "the pin did not animate")
        var failures: [String] = []
        if abs(begin - firstFrame) > 0.0001 {
            failures.append(String(format: "the curve begins %.2f refreshes after the vsync, not 2 (the first frame after the turn)",
                                   (begin - grid) / refresh))
        }
        // Up to the first frame the tab shows where it was (a move that begins later holds its start, never the model).
        for time in [grid + 1.5 * refresh, firstFrame] {
            let shown = Self.shown(cell, at: time)
            if abs(shown.minX - start.minX) > 0.5 {
                failures.append(String(format: "at %.1f refreshes the tab shows at x %.1f, it was at %.1f", (time - grid) / refresh, shown.minX, start.minX))
            }
        }
        // The first moved frame: the strip's move curve at 1 refresh.
        let motion = try #require(MotionMove.tween(.tabMove, in: Motion.tabs))
        let probe = CALayer()
        let curve = motion.additive("position", from: NSValue(point: CGPoint(x: -100, y: 0)), to: NSValue(point: .zero))
        curve.beginTime = firstFrame
        probe.add(curve, forKey: "curve")
        let progress = 1 + MotionPath(probe, "position").value(at: firstFrame + refresh).x / 100
        let expected = start.minX + (end.minX - start.minX) * progress
        let moved = Self.shown(cell, at: firstFrame + refresh).minX
        if abs(moved - expected) > 0.5 {
            failures.append(String(format: "the first moved frame shows x %.1f, curve(1 refresh) is %.1f (progress %.3f)", moved, expected, progress))
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
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

    /// What of `cell` draws at `time`, in the tabs' coordinates: its shown frame cut to its mask's opaque parts (the
    /// mask itself, or each of its sublayers when it has some), each sampled at `time`.
    static func drawn(_ cell: TabCell, at time: CFTimeInterval) -> [CGRect] {
        let frame = shown(cell, at: time)
        guard let mask = cell.layer.mask else { return [frame] }
        let sides = mask.sublayers ?? []
        let parts = sides.isEmpty ? [mask] : sides
        let origin = sides.isEmpty ? CGPoint.zero : mask.frame.origin
        return parts.compactMap { part in
            let center = MotionPath(part, "position").value(at: time), size = MotionPath(part, "bounds.size").value(at: time)
            let rect = CGRect(x: frame.minX + origin.x + center.x - size.x / 2, y: 0, width: max(0, size.x), height: frame.height)
                .intersection(frame)
            return rect.isNull || rect.width <= 0 ? nil : rect
        }
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
        let dividerStart = strip.pinnedDivider.isHidden ? nil : MotionPath(strip.pinnedDivider, "position").value(at: before).x
        model.tabs = tabs(pinned: pin ? [first, moved] : [first])
        strip.sync(fromModel: true)
        #expect(strip.cells[moved] === cell, "the tab's cell was replaced: the same view must move")
        // Frame 0 is the move's begin (`TabStripMove.begin`), not the clock after `sync` returns: a slow host's sync
        // time would otherwise read as a jump.
        let begin = try #require(TabMoveMotionTargetTests.moveBegin(Array(strip.cells.values)), "the pin did not animate")
        // The app syncs the strip a second time while the pin moves (the daemon's echo of the same change: the film's second
        // turn). The screen at a4ccec2: the divider showed at its new place from that turn on, tab1's icon slid under it
        // (3 frames), then it vanished (5 frames). Every reading below is after both syncs, as the screen shows it.
        strip.sync(fromModel: true)
        let ends = Dictionary(uniqueKeysWithValues: strip.cells.map { ($0.key, $0.value.layer.frame) })
        let end = ends[moved] ?? cell.layer.frame
        let endTitle = cell.titleLayer.opacity
        let ticks = MotionPath.sampleCount(seconds: 0.4)
        var failures: [String] = []
        var path: [CGRect] = []
        var titles: [Float] = []
        var icons: [CGFloat] = []
        var iconOverTitle = false
        var separatorOverIcon = false
        var separatorOverMovingTab = false
        for k in 0...ticks {
            let time = begin + Double(k) / 120
            let frame = shown(cell, at: time)
            path.append(frame)
            titles.append(opacity(cell.titleLayer, at: time))
            icons.append(frame.minX + MotionPath(cell.iconLayer, "position").value(at: time).x)
            // The icon never draws over its own title while the title shows (the film: the centring icon passed over
            // its fading title). Both in the cell's coordinates.
            let iconCenter = MotionPath(cell.iconLayer, "position").value(at: time).x
            let iconMaxX = iconCenter + MotionPath(cell.iconLayer, "bounds.size").value(at: time).x * (1 - cell.iconLayer.anchorPoint.x)
            let titleMinX = MotionPath(cell.titleLayer, "position").value(at: time).x
                - MotionPath(cell.titleLayer, "bounds.size").value(at: time).x * cell.titleLayer.anchorPoint.x
            if !iconOverTitle, let titleOpacity = titles.last, titleOpacity > 0.05, iconMaxX > titleMinX + 0.5 {
                iconOverTitle = true
                failures.append("tick \(k): the icon draws \(iconMaxX - titleMinX) pt over its own title (opacity \(titleOpacity))")
            }
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
            // The moving tab is the selected one: its pill's fill is translucent, so a tab it flies over hides the part
            // under the pill (`TabOcclusion`), or its title and icon show through the pill (the film: a doubled icon).
            // Only the part under the pill hides: the rest of a tab it passes draws on every tick (the film: the passed
            // tab's whole label went for 4 frames, also outside the pill, when the mask kept only its larger side).
            let pill = cell.metrics.pillFrame(slotWidth: frame.width, height: frame.height).offsetBy(dx: frame.minX, dy: 0)
            var throughShown = false, hiddenShown = false
            for (id, other) in strip.cells where id != moved {
                let otherFrame = shown(other, at: time)
                let parts = drawn(other, at: time)
                let through = parts.reduce(0) { $0 + $1.intersection(pill).width }
                if !throughShown, through > 0.5 {
                    throughShown = true
                    failures.append("tick \(k): \(id.rawValue) shows \(through) pt through the moving tab's pill")
                }
                let outside = otherFrame.width - otherFrame.intersection(pill).width
                let drawnOutside = parts.reduce(0) { $0 + $1.width - $1.intersection(pill).width }
                if !hiddenShown, outside - drawnOutside > 0.5 {
                    hiddenShown = true
                    failures.append("tick \(k): \(id.rawValue) hides \(outside - drawnOutside) pt outside the moving tab's pill")
                }
            }
            // No separator draws through a tab's icon (the films: the divider left of tab1 slid on its own path and
            // drew through tab1's icon for 4 frames). The divider and every cell's separator, each where it shows.
            var lines: [(String, CGFloat)] = []
            if !strip.pinnedDivider.isHidden, opacity(strip.pinnedDivider, at: time) > 0.05 {
                lines.append(("the divider", MotionPath(strip.pinnedDivider, "position").value(at: time).x))
            }
            // A cell's separator draws only where its cell draws: a passed tab's mask hides the line under the pill.
            for (id, other) in strip.cells where !other.separatorLayer.isHidden && opacity(other.separatorLayer, at: time) > 0.05 {
                let x = shown(other, at: time).minX + MotionPath(other.separatorLayer, "position").value(at: time).x
                if drawn(other, at: time).contains(where: { x > $0.minX && x < $0.maxX }) { lines.append(("\(id.rawValue)'s separator", x)) }
            }
            iconCheck: for (id, other) in strip.cells where !other.iconLayer.isHidden {
                let otherFrame = shown(other, at: time)
                let center = MotionPath(other.iconLayer, "position").value(at: time).x
                let width = MotionPath(other.iconLayer, "bounds.size").value(at: time).x
                let iconMinX = otherFrame.minX + center - width * other.iconLayer.anchorPoint.x
                for (name, x) in lines where x > iconMinX + 0.5 && x < iconMinX + width - 0.5 {
                    if !separatorOverIcon {
                        separatorOverIcon = true
                        failures.append("tick \(k): \(name) at \(x) draws through \(id.rawValue)'s icon \(iconMinX)...\(iconMinX + width)")
                    }
                    break iconCheck
                }
            }
            // No other tab's separator draws over the moving tab (the PIN6 K6 and K12 films: a separator drew over the
            // flying tab's right end for one frame): the moving tab is drawn above the tabs it passes, so a line of one
            // of them shows only where that tab draws (its mask, `drawn`) and never inside the moving tab's frame.
            if !separatorOverMovingTab {
                for (id, other) in strip.cells where id != moved && !other.separatorLayer.isHidden
                    && opacity(other.separatorLayer, at: time) > 0.05 {
                    let x = shown(other, at: time).minX + MotionPath(other.separatorLayer, "position").value(at: time).x
                    guard drawn(other, at: time).contains(where: { x > $0.minX && x < $0.maxX }),
                          x > frame.minX + 0.5, x < frame.maxX - 0.5 else { continue }
                    separatorOverMovingTab = true
                    let place = x > pill.minX + 0.5 && x < pill.maxX - 0.5 ? "inside its pill" : "outside its pill"
                    failures.append("tick \(k): \(id.rawValue)'s separator at \(x) draws over the moving tab \(frame) (\(place) \(pill))")
                    break
                }
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
        // Tick 0 shows the divider where it showed before the pin (or not at all): it never jumps to its new place.
        if let dividerStart, dividerOpacity[0] > 0.05 {
            let x = MotionPath(strip.pinnedDivider, "position").value(at: begin).x
            if abs(x - dividerStart) > 0.5 { failures.append("tick 0: the divider shows at \(x), it showed at \(dividerStart)") }
        }
        for (index, pair) in zip(dividerOpacity, dividerOpacity.dropFirst()).enumerated() where abs(pair.1 - pair.0) > 0.5 {
            failures.append("tick \(index + 1): the divider pops (\(pair.0) to \(pair.1))")
            break
        }
        #expect(failures.isEmpty, "\(pin ? "pin" : "unpin"): \(failures.prefix(16).joined(separator: "\n"))")
    }
}
