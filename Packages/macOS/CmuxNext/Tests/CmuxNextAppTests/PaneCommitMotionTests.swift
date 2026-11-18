import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A split, a close and a zoom move their panes: the frame that shows the change has the layout after it as its model,
/// and each pane whose rect changed goes from its old rect to its new one on its layer.
///
/// - The layout is the one-commit layout (`PaneLayoutCommitTests`): each pane's content has its final size from the
///   frame that shows the change, and no frame of the motion lays a pane out.
/// - The move is a move of a clip: a layer's `position` and `bounds`. No layer is scaled.
/// - A pane that a close took out, and a pane that a zoom covers, show until the motion's end.
/// - The motion ends by the layout's frame clock, in the act's time, and never later than `cap`.
/// - With the motion off (Reduce Motion, pane animations off) an act shows in one frame with no move.
///
/// The test is the clock: it steps the layout's frames itself. It reads each move from the animations on a layer
/// (`move(of:)`), so it reads what the render server gets and commits nothing to it. The oracle for the panes is the
/// layout engine's rest geometry (`PaneLayoutCommitTests.Rest`).
@MainActor
@Suite(.closesItsWindows) struct PaneCommitMotionTests {
    typealias Commit = PaneLayoutCommitTests
    typealias Zoom = PaneZoomMotionTests

    static let dt = PaneMotionBench.frameBudget
    /// The longest a pane's motion may take.
    static let cap: TimeInterval = 0.3

    struct Act: CustomTestStringConvertible, Sendable {
        /// A change of `PaneLayoutCommitTests.layouts(of:)`.
        let name: String
        /// The seconds the act's motion takes.
        let time: TimeInterval
        var testDescription: String { name }
    }

    /// Each time is where the act's spring animation ends, with 0.2 percent of its way left: the motion's frame count
    /// ends there too. A split's 0.115 s, a close's 0.086 s and a zoom's 0.27 s; for the eye (0.5 percent left) they are
    /// 0.10 s, 0.08 s and 0.24 s.
    nonisolated static let split = Act(name: "split right", time: 0.115)
    nonisolated static let close = Act(name: "close", time: 0.086)
    nonisolated static let zoom = Act(name: "zoom", time: 0.27)
    nonisolated static let acts = [split, Act(name: "split down", time: 0.115), close, zoom]

    /// From here on a split, a close and a zoom of `harness` move their panes: the pane animations are on, and the
    /// fixture asks for the move (a fixture that only pins Reduce Motion gets none).
    static func movePanes(_ harness: Commit.Harness) {
        harness.root.context.reduceMotionOverride = false
        harness.root.context.commitMotionOverride = true
    }

    // MARK: What a layer shows

    /// Where one layer shows at the start and at the end of the moves on it, in its superlayer.
    struct Move {
        var start: CGRect
        var end: CGRect
        /// The animations of the layer's `position` and `bounds`.
        var animations: [CABasicAnimation] = []
        /// What is on the layer that a move of a clip does not have.
        var issues: [String] = []

        var moves: Bool { !animations.isEmpty }

        /// The layer's frame when each of its animations is at `part` of its way (0: the start, 1: the end).
        func rect(at part: CGFloat) -> CGRect {
            CGRect(x: start.minX + (end.minX - start.minX) * part, y: start.minY + (end.minY - start.minY) * part,
                   width: start.width + (end.width - start.width) * part, height: start.height + (end.height - start.height) * part)
        }
    }

    /// The numbers that one end of an animation of `path` gives: 0 the position's x, 1 its y, 2 the width, 3 the
    /// height. A bounds origin moves no edge of the layer.
    static func numbers(_ value: Any?, of path: String) -> [Int: CGFloat] {
        guard let value else { return [:] }
        let number = (value as? NSNumber).map { CGFloat($0.doubleValue) }
        let boxed = value is NSNumber ? nil : value as? NSValue
        switch path {
        case "position": return boxed.map { [0: $0.pointValue.x, 1: $0.pointValue.y] } ?? [:]
        case "position.x": return number.map { [0: $0] } ?? [:]
        case "position.y": return number.map { [1: $0] } ?? [:]
        case "bounds": return boxed.map { [2: $0.rectValue.width, 3: $0.rectValue.height] } ?? [:]
        case "bounds.size": return boxed.map { [2: $0.sizeValue.width, 3: $0.sizeValue.height] } ?? [:]
        case "bounds.size.width": return number.map { [2: $0] } ?? [:]
        case "bounds.size.height": return number.map { [3: $0] } ?? [:]
        default: return [:]
        }
    }

    /// The move on `layer`, from its animations (`only`: from the ones with these keys). An additive animation adds to
    /// the layer's model value; another one replaces it.
    static func move(of layer: CALayer, only keys: Set<String>? = nil) -> Move {
        var start = [layer.position.x, layer.position.y, layer.bounds.width, layer.bounds.height]
        var end = start
        var move = Move(start: .zero, end: .zero)
        for key in layer.animationKeys() ?? [] where keys?.contains(key) ?? true {
            guard let animation = layer.animation(forKey: key) as? CABasicAnimation, let path = animation.keyPath else { continue }
            if path.hasPrefix("transform") || path.hasPrefix("sublayerTransform") {
                move.issues.append("an animation of `\(path)`: a move of a clip scales nothing")
                continue
            }
            guard path.hasPrefix("position") || path.hasPrefix("bounds") else { continue }
            move.animations.append(animation)
            let from = numbers(animation.fromValue, of: path), to = numbers(animation.toValue, of: path)
            for index in 0..<4 {
                if let value = from[index] { start[index] = (animation.isAdditive ? start[index] : 0) + value }
                if let value = to[index] { end[index] = (animation.isAdditive ? end[index] : 0) + value }
            }
        }
        let anchor = layer.anchorPoint
        func frame(_ values: [CGFloat]) -> CGRect {
            CGRect(x: values[0] - anchor.x * values[2], y: values[1] - anchor.y * values[3], width: values[2], height: values[3])
        }
        move.start = frame(start)
        move.end = frame(end)
        return move
    }

    /// When and how one animation runs: two animations with one timing stay in step on the render server.
    static func timing(_ animation: CABasicAnimation) -> String {
        let spring = (animation as? CASpringAnimation).map { " spring \($0.mass) \($0.stiffness) \($0.damping)" } ?? ""
        return "\(type(of: animation)) over \(animation.duration) s from \(animation.beginTime)\(spring)"
    }

    /// Whether `animation` is a spring that does not pass its end: critically damped or more.
    static func hasNoBounce(_ animation: CABasicAnimation) -> Bool {
        guard let spring = animation as? CASpringAnimation else { return false }
        return spring.damping >= 2 * (spring.stiffness * spring.mass).squareRoot() - 1e-6
    }

    /// The pane hosts that `screen` shows now, the ones a close took out and a zoom covers too while they show.
    static func hosts(of screen: ScreenContentView) -> [PaneID: PaneHostView] {
        var found: [PaneID: PaneHostView] = [:]
        for case let host as PaneHostView in screen.subviews where !host.isHidden && host.alphaValue > 0 { found[host.pane] = host }
        return found
    }

    /// Whether a pane host of `screen` has a move on its layer: the motion is in flight.
    static func inFlight(_ screen: ScreenContentView) -> Bool {
        screen.subviews.contains { view in (view as? PaneHostView)?.layer.map { move(of: $0).moves } ?? false }
    }

    /// Whether `screen` shows each pane of `rest` at its rest rect. Other panes can show too (the ones that leave).
    static func places(_ rest: Commit.Rest, on screen: ScreenContentView) -> Bool {
        let shown = hosts(of: screen)
        return rest.panes.allSatisfy { pane, rect in shown[pane].map { Commit.near($0.frame, rect) } ?? false }
    }

    /// The area of `bounds` that none of `rects` covers.
    static func uncovered(_ rects: [CGRect], in bounds: CGRect) -> CGFloat {
        let inside = rects.map { $0.intersection(bounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let columns = Set([bounds.minX, bounds.maxX] + inside.flatMap { [$0.minX, $0.maxX] }).sorted()
        let rows = Set([bounds.minY, bounds.maxY] + inside.flatMap { [$0.minY, $0.maxY] }).sorted()
        var area: CGFloat = 0
        for (left, right) in zip(columns, columns.dropFirst()) {
            for (top, bottom) in zip(rows, rows.dropFirst()) {
                let middle = CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)
                if !inside.contains(where: { $0.contains(middle) }) { area += (right - left) * (bottom - top) }
            }
        }
        return area
    }

    // MARK: An act

    /// One act, begun: the screen rested at the layout before it, the act came in its own turn, and the first display
    /// frame after it was stepped. That frame shows the change.
    struct Begun {
        let harness: Commit.Harness
        let screen: ScreenContentView
        /// The layouts before and after the act, at rest.
        let old: Commit.Rest
        let new: Commit.Rest
        /// Each shown pane host's layer frame before the act, and each shown ring's.
        let was: [PaneID: CGRect]
        let rings: [PaneID: CGRect]
        /// Whether the frame that shows the change asked for more frames.
        let asks: Bool
    }

    /// `off`: the motion is off, by "Reduce Motion" or by the pane animations setting (the caller sets that one).
    /// `prepare` runs when the screen rests at the layout before the act.
    static func begin(_ act: Act, off: String? = nil, prepare: (Commit.Harness) -> Void = { _ in }) throws -> Begun {
        let (before, after) = Commit.layouts(of: Commit.Change(name: act.name, holds: false))
        let harness = Commit.Harness(before, focused: Commit.left, holds: false)
        var begun = false
        defer { if !begun { harness.window.closeAfterTest() } }
        if let off {
            harness.root.context.reduceMotionOverride = off == "Reduce Motion" ? true : nil
        } else {
            movePanes(harness)
        }
        Commit.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Commit.Rest(harness.model.screens, in: screen, style: style)
        try #require(old.isShown(by: Commit.shown(screen)), "SETUP: the screen does not rest at the layout before the act")
        prepare(harness)
        let shown = hosts(of: screen)
        let was = shown.compactMapValues { $0.layer?.frame }
        let rings = shown.compactMapValues { $0.chrome.isHidden ? nil : $0.chrome.layer?.frame }
        harness.model.apply(screens: after)
        let new = Commit.Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        let asks = harness.root.advanceFrame(dt)
        begun = true
        return Begun(harness: harness, screen: screen, old: old, new: new, was: was, rings: rings, asks: asks)
    }

    /// Steps display frames until no pane host has a move on its layer, at most `Commit.frames` of them. Returns how
    /// many it stepped and whether the last one asked for more.
    static func toTheEnd(_ harness: Commit.Harness, _ screen: ScreenContentView) -> (ticks: Int, asks: Bool) {
        var ticks = 0, asks = true
        while inFlight(screen), ticks < Commit.frames {
            asks = harness.root.advanceFrame(dt)
            ticks += 1
        }
        return (ticks, asks)
    }

    // MARK: Tests

    /// The frame that shows an act has the layout after it as its model, and each pane whose rect changed has a move
    /// on its layer from where it showed before the act. The move scales nothing, it is a spring that does not pass
    /// its end, and every pane's move has one timing.
    @Test(arguments: acts)
    func aMovedPaneHasItsMoveOnItsLayer(_ act: Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let hosts = Self.hosts(of: begun.screen)
        #expect(Self.places(begun.new, on: begun.screen),
                "the first frame after the act does not have each pane of the new layout at its rest rect: \(hosts.mapValues(\.frame))")
        var moved = 0
        for (pane, was) in begun.was {
            guard let rect = begun.new.panes[pane], let old = begun.old.panes[pane], !Commit.near(old, rect) else { continue }
            moved += 1
            let layer = try #require(hosts[pane]?.layer, "\(pane) does not show in the frame that shows the act")
            let move = Self.move(of: layer)
            #expect(move.moves, "\(pane) went from \(old) to \(rect) with no move on its layer: it shows at its new rect at once")
            #expect(Commit.near(move.start, was), "\(pane)'s move starts at \(move.start), not where the pane showed: \(was)")
            #expect(Commit.near(move.end, layer.frame), "\(pane)'s move ends at \(move.end), not at its layer's frame: \(layer.frame)")
            #expect(move.issues.isEmpty, "\(pane): \(move.issues)")
            for animation in move.animations {
                #expect(animation.duration >= act.time / 2 && animation.duration <= Self.cap,
                        "\(pane)'s move takes \(animation.duration) s; the act's time is \(act.time) s and no motion is longer than \(Self.cap) s")
                #expect(Self.hasNoBounce(animation), "\(pane)'s move is no spring, or a spring that passes its end: \(Self.timing(animation))")
            }
        }
        #expect(moved > 0, "SETUP: the act changed no pane's rect")
        let timings = Set(hosts.values.compactMap(\.layer).flatMap { Self.move(of: $0).animations }.map { Self.timing($0) })
        #expect(timings.count <= 1, "the panes of one act move with \(timings.count) timings: their edges part on the way: \(timings)")
        #expect(begun.asks || !Self.inFlight(begun.screen), "panes move and no frame is asked for: nothing ends the motion")
    }

    /// At the start, at each quarter and at the end of the motion the panes cover what the layouts cover: the area of
    /// the screen that no pane covers is never more than before the act or after it. A pane that comes starts with
    /// no area, a pane that leaves ends with none, and a zoom's pane grows over the panes that it covers.
    @Test(arguments: acts)
    func eachSampleOfTheMotionCoversTheScreen(_ act: Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let bounds = try #require(begun.screen.layer?.bounds)
        let moves = Self.hosts(of: begun.screen).values.compactMap(\.layer).map { Self.move(of: $0) }
        try #require(moves.contains { $0.moves }, "no pane moves: the act shows in one frame")
        let slack = bounds.width + bounds.height
        let atStart = Self.uncovered(moves.map { $0.rect(at: 0) }, in: bounds), atEnd = Self.uncovered(moves.map { $0.rect(at: 1) }, in: bounds)
        let before = Self.uncovered(Array(begun.was.values), in: bounds)
        #expect(abs(atStart - before) <= slack, "the motion's start leaves \(atStart) pt2 of the screen with no pane; the layout before the act left \(before)")
        for part in [0.25, 0.5, 0.75] as [CGFloat] {
            let open = Self.uncovered(moves.map { $0.rect(at: part) }, in: bounds)
            #expect(open <= max(atStart, atEnd) + slack,
                    "at \(part) of the motion \(open) pt2 of the screen has no pane; the start leaves \(atStart) and the end \(atEnd)")
        }
    }

    /// Each pane's content has its final size and place in the frame that shows the act, and no frame of the motion
    /// lays a pane out: no clip layout runs and no content takes a size.
    @Test(arguments: acts)
    func noPaneIsLaidOutInAFrameOfTheMotion(_ act: Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        try #require(Self.inFlight(begun.screen), "no pane moves: the act shows in one frame")
        let first = Commit.shown(begun.screen)
        for pane in begun.new.panes.keys {
            #expect(first.misfits[pane] == nil, "\(pane)'s content is not at the rect its pane gives it in the frame that shows the act")
        }
        let hosts = Self.hosts(of: begun.screen).filter { begun.new.panes[$0.key] != nil }
        let layouts = hosts.mapValues(\.clipLayouts)
        let sizes = begun.harness.provider.contents.mapValues(\.sizes.count)
        var tick = 1
        while Self.inFlight(begun.screen), tick < Commit.frames {
            _ = begun.harness.root.advanceFrame(Self.dt)
            tick += 1
            for (pane, host) in hosts {
                #expect(host.clipLayouts == layouts[pane], "frame \(tick): \(pane)'s clip was laid out in a frame of the motion")
            }
            for (pane, content) in begun.harness.provider.contents where begun.new.panes[pane] != nil {
                #expect(content.sizes.count == sizes[pane], "frame \(tick): \(pane)'s content took a size in a frame of the motion: \(content.sizes)")
            }
        }
    }

    /// The motion ends by the layout's frame clock in the act's time: frames are asked for while a pane moves, the
    /// frame that ends it leaves the layout after the act alone on the screen, and no frame is asked for after it.
    @Test(arguments: acts)
    func theMotionEndsByItsTime(_ act: Act) throws {
        let begun = try Self.begin(act)
        defer { begun.harness.window.closeAfterTest() }
        let harness = begun.harness, screen = begun.screen
        try #require(Self.inFlight(screen), "no pane moves: the act shows in one frame")
        var ticks = 0, asks = begun.asks
        while Self.inFlight(screen), ticks < Commit.frames {
            #expect(asks, "\(ticks) frames into the motion no frame is asked for: nothing ends the motion")
            asks = harness.root.advanceFrame(Self.dt)
            ticks += 1
        }
        let spent = Double(ticks) * Self.dt
        #expect(spent >= act.time / 2 && spent <= act.time + 2 * Self.dt, "the motion ended \(spent) s after the frame that began it; its time is \(act.time) s")
        #expect(begun.new.isShown(by: Commit.shown(screen)), "after the motion's end the screen shows more or less than the layout after the act: \(Commit.shown(screen).panes)")
        #expect(PaneZoomDimTests.dim(harness) == nil, "a dim shows after the motion's end")
        #expect(!harness.root.advanceFrame(Self.dt) || !harness.root.advanceFrame(Self.dt), "frames run on after the motion's end")
    }

    /// With the motion off an act shows in one frame, as before the motion: the frame that shows it has the layout
    /// after it alone, no pane has a move on its layer, no dim shows, and no frame is asked for.
    @Test(arguments: acts, ["Reduce Motion", "pane animations off"])
    func withTheMotionOffAnActShowsInOneFrame(_ act: Act, off: String) throws {
        // The setting is the app's own (`ui.paneAnimations`). This function has no suspension point, so no other test
        // on the main actor runs between the change and its restore.
        let setting = DesignSettings.shared.paneAnimations
        if off != "Reduce Motion" { DesignSettings.shared.paneAnimations = false }
        defer { DesignSettings.shared.paneAnimations = setting }
        let begun = try Self.begin(act, off: off)
        defer { begun.harness.window.closeAfterTest() }
        let context = begun.harness.root.context
        try #require(context.reduceMotion || !context.animatesPaneLayout, "SETUP: the pane animations are on")
        #expect(begun.new.isShown(by: Commit.shown(begun.screen)), "the first frame after the act does not show its layout alone: \(Commit.shown(begun.screen).panes)")
        #expect(!Self.inFlight(begun.screen), "a pane has a move on its layer with the motion off")
        #expect(PaneZoomDimTests.dim(begun.harness) == nil, "a dim shows with the motion off")
        #expect(!begun.harness.root.advanceFrame(Self.dt) || !begun.harness.root.advanceFrame(Self.dt), "frames run on with the motion off")
    }
}
