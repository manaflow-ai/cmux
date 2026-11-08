import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Lawrence 2026-11-08 (cmux-ad m70): "animation when i pin stuff and unpin stuff is not very good. like it needs to
/// translate properly from its original position to new position". On the sidebar document a pin closed the list row
/// in place (a fade) and grew a new Pinned item out of an empty frame at the block's corner; an unpin dropped the item
/// and faded a new row in at its slot. A pin or an unpin now moves the workspace from where it is drawn to its new slot
/// on the rows' one spring: every 120 Hz tick shows exactly one copy of it, the first tick shows it where it was, it
/// never passes its slot, its size changes on the move's progress, and the rows between slide one slot.
@MainActor @Suite(.serialized, .closesItsWindows, .enabled(if: !NSScreen.screens.isEmpty))
struct SidebarPinFlightTests {
    static let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
    static let home = LayoutItem(id: LayoutItemID("itm_home"), ref: SidebarLayoutDocument.homeRef)
    /// `p` is pinned in every state (the Pinned block exists before the pin); `d` moves.
    static let listed = ["a", "b", "c", "d", "e"].map(WorkspaceID.init)
    static let anchor = WorkspaceID("p")
    static let moved = WorkspaceID("d")
    static let ticks = MotionPath.sampleCount(seconds: 0.8)

    /// Home's block, Pinned (`p`, then each of `pins`) and the machine's rows (every listed workspace not pinned).
    /// `anchored` false: no `p`, and with no pins no Pinned section at all (the first pin creates it).
    static func state(_ pins: [WorkspaceID], anchored: Bool = true,
                      listed: [WorkspaceID] = SidebarPinFlightTests.listed) -> (sections: [SidebarSection], blocks: SidebarListBlocks) {
        let pinned = (anchored ? [anchor] : []) + pins
        let items = pinned.map { LayoutItem(id: LayoutItemID("itm_pin_\($0.rawValue)"), ref: .workspace($0.rawValue)) }
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let section = SidebarLayoutDocument.pinnedSection(items: items)
        var infos = [home.id: SidebarItemInfo.fallback(for: home)]
        for (item, workspace) in zip(items, pinned) {
            var info = SidebarItemInfo(title: workspace.rawValue, symbol: "terminal")
            info.workspace = workspace
            infos[item.id] = info
        }
        let hasPinned = !pinned.isEmpty
        let sections = [SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: [])]
            + (hasPinned ? [SidebarSection(kind: .custom(SidebarCustomSection(id: section.id.rawValue)), nodes: [])] : [])
            + [SidebarSection(kind: .machine(machine), nodes: listed.filter { !pinned.contains($0) }
                .map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) })]
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        let blocks = SidebarListBlocks(sections: hasPinned ? [top.id.rawValue: top, section.id.rawValue: section] : [top.id.rawValue: top],
                                       infos: infos, collapsed: [],
                                       look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        return (sections, blocks)
    }

    /// The list shows `pins` pinned (the sidebar's blocks and rows change together, as the app's pin does).
    static func show(_ pins: [WorkspaceID], anchored: Bool = true, listed: [WorkspaceID] = SidebarPinFlightTests.listed,
                     on list: SidebarListView) {
        let (sections, blocks) = state(pins, anchored: anchored, listed: listed)
        list.blocks = blocks
        list.model.sections = sections
    }

    static func list(pins: [WorkspaceID], anchored: Bool = true) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (sections, blocks) = state(pins, anchored: anchored)
        let list = SidebarListView(model: SidebarModel(sections: sections))
        list.blocks = blocks
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        list.leftButtonIsDown = { false }
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        return (list, window)
    }

    // MARK: - What the screen shows at a media time

    /// One view's drawn frame in the list and its opacity at any time, from the animations on it and its containers
    /// (captured once: a later change does not alter the path already sampled).
    struct Probe {
        struct Node {
            let model: CGPoint
            let position: MotionPath
            let opacity: (CFTimeInterval) -> Float
            let clips: Bool
            let bounds: CGRect // in the list, at rest
        }
        let view: NSView
        /// Shown when the probe was made (in a window, not hidden): a later apply that takes the view out does not
        /// change the path already captured.
        let attached: Bool
        let rest: CGRect
        let size: MotionPath
        let nodes: [Node]

        init(_ view: NSView, in list: NSView, now: CFTimeInterval) {
            self.view = view
            attached = view.window != nil && !view.isHiddenOrHasHiddenAncestor
            rest = list.convert(view.bounds, from: view)
            size = MotionPath(view.layer ?? CALayer(), "bounds.size", now: now)
            var nodes: [Node] = []
            var current: NSView? = view
            while let node = current, node !== list {
                if let layer = node.layer {
                    nodes.append(Node(model: layer.position, position: MotionPath(layer, "position", now: now),
                                      opacity: Self.opacity(of: layer, now: now), clips: node !== view && node.clipsToBounds,
                                      bounds: list.convert(node.bounds, from: node)))
                }
                current = node.superview
            }
            self.nodes = nodes
        }

        /// The layer's opacity at a time: its model value, or a running basic animation's value (linear in time, which
        /// is enough to tell shown from not shown).
        static func opacity(of layer: CALayer, now: CFTimeInterval) -> (CFTimeInterval) -> Float {
            let model = layer.opacity
            let fades = (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CABasicAnimation }
                .filter { $0.keyPath == "opacity" }
            return { time in
                var value = model
                for fade in fades {
                    let begin = fade.beginTime == 0 ? now : fade.beginTime
                    let duration = max(fade.duration, .ulpOfOne)
                    let from = (fade.fromValue as? NSNumber)?.floatValue ?? model
                    let to = (fade.toValue as? NSNumber)?.floatValue ?? model
                    if time < begin {
                        if fade.fillMode == .backwards || fade.fillMode == .both { value = from }
                    } else if time < begin + duration {
                        value = from + (to - from) * Float((time - begin) / duration)
                    }
                }
                return value
            }
        }

        /// Why it shows or not at `time` (a failure's detail): attached, opacity, size and the view's type.
        func describe(at time: CFTimeInterval) -> String {
            let size = self.size.value(at: time)
            let opacity = nodes.reduce(Float(1)) { $0 * $1.opacity(time) }
            return "\(type(of: view)) attached \(attached) size \(size.x)x\(size.y) exact \(self.size.isExact) opacity \(opacity)"
        }

        /// Its frame in the list and its opacity at `time`, clipped by the containers that clip; nil when nothing shows.
        func shown(at time: CFTimeInterval) -> (frame: CGRect, opacity: Float)? {
            guard attached else { return nil }
            var offset = CGPoint.zero
            var opacity: Float = 1
            var clip: CGRect?
            // Containers first (outermost last in `nodes`): a clip moves with its own container's offset.
            var offsets: [CGPoint] = Array(repeating: .zero, count: nodes.count)
            var total = CGPoint.zero
            for index in nodes.indices.reversed() {
                let node = nodes[index]
                let value = node.position.value(at: time)
                total.x += value.x - node.model.x
                total.y += value.y - node.model.y
                offsets[index] = total
            }
            for (index, node) in nodes.enumerated() {
                opacity *= node.opacity(time)
                if node.clips {
                    let box = node.bounds.offsetBy(dx: offsets[index].x, dy: offsets[index].y)
                    clip = clip.map { $0.intersection(box) } ?? box
                }
            }
            offset = offsets.first ?? .zero
            let size = self.size.value(at: time)
            var frame = CGRect(x: rest.minX + offset.x, y: rest.minY + offset.y, width: size.x, height: size.y)
            guard frame.width > 0.5, frame.height > 0.5, opacity > 0.02 else { return nil }
            if let clip {
                let visible = frame.intersection(clip)
                guard !visible.isNull, visible.width > 0.5, visible.height > 0.5 else { return nil }
                frame = frame.standardized
            }
            return (frame, opacity)
        }
    }

    /// Every view in the list that draws workspace `id`: its list row and any block item.
    static func copies(of id: WorkspaceID, in list: SidebarListView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if let row = view as? SidebarRowView, row.key == .workspace(id) { found.append(row) }
            if let item = view as? SidebarItemRowView, item.info.workspace == id { found.append(item) }
            view.subviews.forEach(walk)
        }
        list.subviews.forEach(walk)
        return found
    }

    static func probes(_ id: WorkspaceID, _ list: SidebarListView, now: CFTimeInterval) -> [Probe] {
        copies(of: id, in: list).map { Probe($0, in: list, now: now) }
    }

    /// The frame `id` is drawn on at `time` when exactly one copy shows, else the failure.
    static func one(_ probes: [Probe], at time: CFTimeInterval) -> Result<CGRect, Failure> {
        let shown = probes.compactMap { $0.shown(at: time) }
        guard shown.count == 1 else {
            return .failure(Failure(text: "\(shown.count) copies show: \(shown.map { "\($0.frame) at \($0.opacity)" }) of "
                + "\(probes.map { $0.describe(at: time) })"))
        }
        return .success(shown[0].frame)
    }

    struct Failure: Error { let text: String }

    /// The path of one workspace over the ticks: each tick shows exactly one copy, the first tick is on `start`, the path
    /// ends on `end`, it never goes back or past `end`, and the size changes on the move's progress.
    static func checkPath(_ name: String, probes: [Probe], now: CFTimeInterval, start: CGRect, end: CGRect, failures: inout [String]) {
        var frames: [CGRect] = []
        for tick in 0..<ticks {
            switch one(probes, at: now + Double(tick) / 120) {
            case let .success(frame): frames.append(frame)
            case let .failure(failure): failures.append("\(name) tick \(tick): \(failure.text)")
            }
        }
        guard frames.count == ticks, let first = frames.first, let last = frames.last else { return }
        func far(_ a: CGRect, _ b: CGRect) -> CGFloat {
            max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
        }
        if far(first, start) > 0.5 { failures.append("\(name): tick 0 jumps \(far(first, start)) pt (\(first), was \(start))") }
        if far(last, end) > 0.5 { failures.append("\(name): ends on \(last), its slot is \(end)") }
        let dy = end.minY - start.minY, dx = end.minX - start.minX
        let axis: (CGRect) -> CGFloat = abs(dy) >= abs(dx) ? { $0.minY } : { $0.minX }
        let travel = abs(dy) >= abs(dx) ? dy : dx
        guard abs(travel) > 1 else { return }
        let sign: CGFloat = travel > 0 ? 1 : -1
        var overshoot: CGFloat = 0, back: CGFloat = 0
        for (index, frame) in frames.enumerated() {
            overshoot = max(overshoot, (axis(frame) - axis(end)) * sign)
            if index > 0 { back = max(back, (axis(frames[index - 1]) - axis(frame)) * sign) }
            let progress = (axis(frame) - axis(start)) / travel
            for (from, to, now) in [(start.width, end.width, frame.width), (start.height, end.height, frame.height)] where abs(to - from) > 1 {
                let sized = (now - from) / (to - from)
                if abs(sized - progress) > 0.05 {
                    failures.append("\(name) tick \(index): size at \(sized) of its change, the move at \(progress)")
                    break
                }
            }
        }
        if overshoot > 0.5 { failures.append("\(name): passes its slot by \(overshoot) pt") }
        if back > 0.25 { failures.append("\(name): goes back \(back) pt") }
    }

    /// When the move carrying `view` begins (media time): the latest begin of its `move` springs.
    static func moveBegin(of view: NSView) -> CFTimeInterval? {
        guard let layer = view.layer else { return nil }
        return (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(SidebarDragSpring.batchKey).") }
            .compactMap { layer.animation(forKey: $0)?.beginTime }.map { layer.convertTime($0, to: nil) }.max()
    }

    /// The first frame that can show a move is the one after the turn that starts it: a move that begins before that
    /// turn ends shows already advanced on its first frame (a step off the leaving view, p1 films 31fec6d8: about 13%
    /// of the way on SB-PIN). Records a failure when `view`'s move begins before `turnEnd`.
    static func checkBegin(_ name: String, of view: NSView, turnEnd: CFTimeInterval, failures: inout [String]) {
        guard let begin = moveBegin(of: view) else { return failures.append("\(name): no move carries it") }
        if begin < turnEnd {
            failures.append("\(name): the move begins \(String(format: "%.2f", (turnEnd - begin) * 1000)) ms before its turn ends")
        }
    }

    /// The flying view hides what it passes (p1 films 31fec6d8: its title printed over the rows' titles): it draws
    /// above them on an opaque ground of its own while it flies.
    static func checkOpaque(_ name: String, _ view: NSView, failures: inout [String]) {
        // The next display pass paints the row's own fill (its selection) on its layer: the ground must survive it.
        if let row = view as? SidebarRowView {
            row.isSelected = true
            row.updateLayer()
        }
        let alpha = view.layer?.backgroundColor?.alpha ?? 0
        if alpha < 1 { failures.append("\(name): flies see-through (ground alpha \(alpha))") }
        if (view.layer?.zPosition ?? 0) < 1 { failures.append("\(name): flies under the rows it passes") }
    }

    /// A pin's item shows its pin glyph as the move goes, on the move's spring and begin (m70: the look changes on the same
    /// curve and progress as the move), not at once on its first frame.
    static func checkGlyph(_ name: String, _ item: NSView, failures: inout [String]) {
        // The item's glyphs (its pin among them): the one that fades in.
        let glyphs = item.subviews.filter { $0 is NSImageView && !$0.isHidden }.compactMap(\.layer)
        guard !glyphs.isEmpty else { return failures.append("\(name): draws no glyph") }
        let faded = glyphs.lazy.compactMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
                .first { $0.keyPath == "opacity" }.map { (layer, $0) }
        }.first
        let layer = faded?.0, fade = faded?.1
        let move = (item.layer?.animationKeys() ?? []).compactMap { item.layer?.animation(forKey: $0) as? CASpringAnimation }
            .first { $0.keyPath == "position" }
        guard let layer, let fade, let move else { return failures.append("\(name): the pin glyph shows at once (no fade on the move)") }
        let fadeFrom = (fade.fromValue as? NSNumber)?.doubleValue ?? 1
        if fadeFrom > 0.001 { failures.append("\(name): the pin glyph starts at opacity \(fadeFrom)") }
        let fadeBegin = layer.convertTime(fade.beginTime, to: nil), moveBegin = item.layer.map { $0.convertTime(move.beginTime, to: nil) } ?? 0
        if abs(fadeBegin - moveBegin) > 0.0005 || fade.stiffness != move.stiffness || fade.damping != move.damping || fade.mass != move.mass {
            failures.append("\(name): the pin glyph fades on another curve or begin than the move")
        }
    }

    /// An unpin: the item's pin glyph does not vanish on the first frame. It rides the arriving row and fades out on the
    /// move's spring and begin (the pin's fade-in, reversed), and it is gone when the move ends (model opacity 0).
    static func checkLeavingGlyph(_ name: String, _ row: NSView, failures: inout [String]) {
        let move = (row.layer?.animationKeys() ?? []).compactMap { row.layer?.animation(forKey: $0) as? CASpringAnimation }
            .first { $0.keyPath == "position" }
        let fading = row.subviews.lazy.filter { $0 is NSImageView && !$0.isHidden }.compactMap(\.layer).compactMap { layer in
            (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) as? CASpringAnimation }
                .first { $0.keyPath == "opacity" && (($0.fromValue as? NSNumber)?.doubleValue ?? 0) > 0.99 }.map { (layer, $0) }
        }.first
        guard let move, let fading else {
            return failures.append("\(name): the pin glyph vanishes on the first frame (no fade-out on the move)")
        }
        let (layer, fade) = fading
        if layer.opacity > 0.001 { failures.append("\(name): the pin glyph stays after the move (opacity \(layer.opacity))") }
        let fadeBegin = layer.convertTime(fade.beginTime, to: nil), moveBegin = row.layer.map { $0.convertTime(move.beginTime, to: nil) } ?? 0
        if abs(fadeBegin - moveBegin) > 0.0005 || fade.stiffness != move.stiffness || fade.damping != move.damping || fade.mass != move.mass {
            failures.append("\(name): the pin glyph fades out on another curve or begin than the move")
        }
    }

    /// Where each workspace other than `moved` is drawn at rest (row or item).
    static func rest(_ list: SidebarListView) -> [WorkspaceID: CGRect] {
        var frames: [WorkspaceID: CGRect] = [:]
        for id in listed + [anchor] where id != moved {
            if let view = copies(of: id, in: list).first(where: { !$0.isHiddenOrHasHiddenAncestor }) {
                frames[id] = list.convert(view.bounds, from: view)
            }
        }
        return frames
    }

    /// Pins or unpins `d` with motion and checks its path and every other workspace's. `anchored` false: `d` is the only
    /// pinned workspace, so the pin creates the Pinned block (and the unpin empties it).
    func move(pin: Bool, anchored: Bool = true) throws {
        let (list, window) = Self.list(pins: pin ? [] : [Self.moved], anchored: anchored)
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        let before = Self.rest(list)
        Self.show(pin ? [Self.moved] : [], anchored: anchored, on: list)
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let others = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, Self.probes($0, list, now: now)) })
        let after = Self.rest(list)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkBegin(pin ? "pinned d" : "unpinned d", of: arrived, turnEnd: now, failures: &failures)
        Self.checkOpaque(pin ? "pinned d" : "unpinned d", arrived, failures: &failures)
        if pin { Self.checkGlyph("pinned d", arrived, failures: &failures) } else { Self.checkLeavingGlyph("unpinned d", arrived, failures: &failures) }
        Self.checkPath(pin ? "pinned d" : "unpinned d", probes: probes, now: now, start: startFrame,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        // It translates, never fades: the one copy shown is opaque at every tick (a new block must not fade it in).
        for tick in 0..<Self.ticks {
            let shown = probes.compactMap { $0.shown(at: now + Double(tick) / 120) }
            if let faded = shown.first(where: { $0.opacity < 0.98 }) {
                failures.append("\(pin ? "pinned d" : "unpinned d") tick \(tick): drawn at opacity \(faded.opacity), not opaque")
                break
            }
        }
        for (id, from) in before {
            guard let to = after[id], let probes = others[id] else { failures.append("\(id.rawValue) is gone"); continue }
            Self.checkPath(id.rawValue, probes: probes, now: now, start: from, end: to, failures: &failures)
        }
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    /// The pin's curve starts on the first frame that can show it, the vsync after the turn (Chrome: an animation starts
    /// at the time of the first frame that ticks it): that frame shows the row where it was and the next one curve(1
    /// refresh) of the move's spring, also when the turn crosses a refresh. Before: one refresh from the turn on any
    /// phase, so the first moved frame showed between 0 and 1 refresh of the curve.
    @Test func aPinsCurveStartsOnTheFirstFrameThatCanShowIt() throws {
        let (list, window) = Self.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let refresh = 1.0 / 120
        let grid = CACurrentMediaTime()
        list.frameClock = MotionFrameClock(now: { grid + 1.3 * refresh }, vsync: { (grid, refresh) }, refresh: { refresh })
        let firstFrame = grid + 2 * refresh
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        Self.show([Self.moved], on: list)
        list.reload(animated: true)
        let probes = Self.probes(Self.moved, list, now: grid)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let end = list.convert(arrived.bounds, from: arrived)
        var failures: [String] = []
        let begin = try #require(Self.moveBegin(of: arrived), "the pin did not animate")
        if abs(begin - firstFrame) > 0.0001 {
            failures.append(String(format: "the curve begins %.2f refreshes after the vsync, not 2 (the first frame after the turn)",
                                   (begin - grid) / refresh))
        }
        for time in [grid + 1.5 * refresh, firstFrame] {
            switch Self.one(probes, at: time) {
            case let .success(frame) where abs(frame.minY - startFrame.minY) > 0.5:
                failures.append(String(format: "at %.1f refreshes the row shows at y %.1f, it was at %.1f", (time - grid) / refresh, frame.minY, startFrame.minY))
            case let .failure(failure): failures.append("at \((time - grid) / refresh) refreshes: \(failure.text)")
            default: break
            }
        }
        let spring = try #require(arrived.layer.flatMap { layer in
            (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(SidebarDragSpring.batchKey).") }
                .compactMap { layer.animation(forKey: $0) as? CASpringAnimation }.first
        }, "the pin's move has no spring")
        let expected = startFrame.minY + (end.minY - startFrame.minY) * MotionPath.springProgress(spring, at: refresh)
        if case let .success(frame) = Self.one(probes, at: firstFrame + refresh), abs(frame.minY - expected) > 0.5 {
            failures.append(String(format: "the first moved frame shows y %.1f, curve(1 refresh) is %.1f", frame.minY, expected))
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    @Test func aPinMovesTheRowToItsPinnedSlot() throws { try move(pin: true) }

    @Test func anUnpinMovesTheItemBackToItsRow() throws { try move(pin: false) }

    /// The first pin creates the Pinned block: the row still translates into it, opaque, and the block opens around it
    /// (brief item 6c: the new block's open fade took the item with it).
    @Test func theFirstPinMovesTheRowIntoTheNewBlock() throws { try move(pin: true, anchored: false) }

    /// The last unpin empties the Pinned block: the item translates back to its row.
    @Test func theLastUnpinMovesTheItemOutOfTheBlock() throws { try move(pin: false, anchored: false) }

    /// The rows reach the list before the blocks (the sidebar now sends them in one apply, `SidebarPinOneApplyTests`; a
    /// client that sends two updates still must not jump): at the rows' update the row starts to close, and the block's
    /// item then flies from where the closing row is drawn. Nothing waits for the second update (no hold, no timer).
    @Test func aPinWhoseBlockComesLaterStartsOnTheClosingRow() throws {
        let (list, window) = Self.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        // The window draws once before the pin, as the app's sidebar has: the gap between the two updates is the client's
        // (20 ms here), not a new window's first display pass on the test host (about 150 ms on the fleet's display workers,
        // which the render server spent closing the row before the blocks came).
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        var pinnedNow = false
        list.model.workspacePin = (isPinned: { pinnedNow && $0 == Self.moved }, toggle: { _ in })
        let (sections, blocks) = Self.state([Self.moved])
        list.model.sections = sections
        let rowsStart = CACurrentMediaTime()
        list.reload(animated: true)
        let rowsEnd = CACurrentMediaTime()
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        // The closing row's path, read before the item takes over (the row goes in that apply).
        let probed = CACurrentMediaTime()
        let closing = Self.probes(Self.moved, list, now: probed)
        pinnedNow = true
        list.blocks = blocks
        list.reload(animated: true)
        let turnEnd = CACurrentMediaTime()
        // Where the time between the two updates went (ms): the rows' apply, the wait for the blocks, the blocks' apply.
        func ms(_ a: CFTimeInterval, _ b: CFTimeInterval) -> String { String(format: "%.1f", (b - a) * 1000) }
        let timing = "rows apply \(ms(rowsStart, rowsEnd)) ms, then \(ms(rowsEnd, probed)) ms to the blocks, blocks apply \(ms(probed, turnEnd)) ms"
        print("pin-closing-row timing: \(timing)")
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkBegin("pinned d (rows first)", of: arrived, turnEnd: turnEnd, failures: &failures)
        // Where the person sees the workspace when the item takes over: the closing row's path at the move's begin.
        let now = Self.moveBegin(of: arrived) ?? turnEnd
        print("pin-closing-row timing: the item begins \(ms(turnEnd, now)) ms after the blocks' turn, \(ms(rowsStart, now)) ms after the rows' apply")
        // A client's two updates come a frame or two apart. A host that stalls the run loop past the row's close (the
        // fleet's display workers spent about 150 ms on a new window's first display pass) tests nothing: say so.
        try #require(now - rowsStart < 0.1, "SETUP: the item begins \(ms(rowsStart, now)) ms after the rows' update (\(timing)), past the close")
        let drawnStart: CGRect
        switch Self.one(closing, at: now) {
        case let .success(frame): drawnStart = frame
        case let .failure(failure):
            Issue.record("the closing row at the item's begin: \(failure.text) (\(timing); the item begins \(ms(rowsStart, now)) ms after the rows' apply)")
            return
        }
        let probes = Self.probes(Self.moved, list, now: now)
        Self.checkPath("pinned d (rows first)", probes: probes, now: now, start: drawnStart,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    /// The app's unpin can send the rows first while the block still lists the item (films d007faa2, revision 18): the
    /// row moves from the item, and the item hides until the blocks' update takes it out (one copy on every tick).
    @Test func anUnpinWhoseBlockComesLaterStartsOnTheItem() throws {
        let (list, window) = Self.list(pins: [Self.moved])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        list.model.workspacePin = (isPinned: { $0 == Self.moved }, toggle: { _ in })
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        let (sections, blocks) = Self.state([])
        list.model.sections = sections
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let arrived = try #require(list.rowViews[.workspace(Self.moved)])
        var failures: [String] = []
        Self.checkPath("unpinned d (rows first)", probes: probes, now: now, start: startFrame,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
        list.blocks = blocks
        list.reload(animated: true)
    }

    /// Pin, then unpin 60 ms later: the unpin starts where the pin has the workspace drawn (no jump), with one copy on
    /// every tick, and moves to its row from rest (no velocity carried: it never passes the row).
    @Test func aRetargetStartsWhereTheMoveIs() throws {
        let (list, window) = Self.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        Self.show([Self.moved], on: list)
        list.reload(animated: true)
        let firstNow = CACurrentMediaTime()
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
        let pinning = Self.probes(Self.moved, list, now: firstNow)
        Self.show([], on: list)
        list.reload(animated: true)
        let turnEnd = CACurrentMediaTime()
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkBegin("unpin over a pin", of: arrived, turnEnd: turnEnd, failures: &failures)
        // The hand-off is the instant the unpin's move begins: the pin's path (captured before it) at that instant is
        // where the person sees the workspace, and the unpin's path must start exactly there.
        let now = try #require(Self.moveBegin(of: arrived), "no move carries the unpinned row")
        let drawn: CGRect
        switch Self.one(pinning, at: now) {
        case let .success(frame): drawn = frame
        case let .failure(failure):
            Issue.record("the pin at the unpin: \(failure.text)")
            return
        }
        let probes = Self.probes(Self.moved, list, now: now)
        Self.checkPath("unpin over a pin", probes: probes, now: now, start: drawn,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    // MARK: - A target out of view (the contract: "Target off-screen: the scroll follows, or the row slides out of view")

    /// `a`, `b`, `c`, 30 more, then `d` and `e`: `d`'s list slot is far below a 300 pt clip.
    static let long = Array(listed.prefix(3)) + (0..<30).map { WorkspaceID("f\($0)") } + [moved, WorkspaceID("e")]

    /// The list in a 300 pt scroll view (as the sidebar has it): only the rows near the clip have views.
    static func scrolledList(pins: [WorkspaceID]) -> (SidebarListView, NSScrollView, NSWindow) {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (sections, blocks) = state(pins, listed: long)
        let list = SidebarListView(model: SidebarModel(sections: sections))
        list.blocks = blocks
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 300))
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = list
        window.contentView = scroll
        list.leftButtonIsDown = { false }
        window.orderFrontRegardless()
        list.fitToClip()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        return (list, scroll, window)
    }

    /// Unpin `d` while its list slot is out of view: the item still moves from where it is drawn toward that slot and
    /// slides out of view, one copy on every tick. It must not vanish because its row has no view yet.
    @Test func anUnpinToASlotOutOfViewSlidesOutOfView() throws {
        let (list, scroll, window) = Self.scrolledList(pins: [Self.moved])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        Self.show([], listed: Self.long, on: list)
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let slot = try #require(list.displayed.row(for: .workspace(Self.moved)).map { list.frame(for: $0) })
        #expect(!slot.intersects(scroll.contentView.bounds), "the fixture's slot \(slot) is in view")
        let arrived = try #require(list.rowViews[.workspace(Self.moved)], "the unpinned row has no view: the item vanished")
        var failures: [String] = []
        Self.checkOpaque("unpinned d (out of view)", arrived, failures: &failures)
        Self.checkPath("unpinned d (out of view)", probes: probes, now: now, start: startFrame, end: slot, failures: &failures)
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    /// The workspace rows whose views intersect the clip (`d` aside), at rest, in the list.
    static func inView(_ list: SidebarListView, clip: CGRect) -> [WorkspaceID: CGRect] {
        var frames: [WorkspaceID: CGRect] = [:]
        for (key, view) in list.rowViews where !view.isHiddenOrHasHiddenAncestor {
            guard case let .workspace(id) = key, id != moved else { continue }
            let frame = list.convert(view.bounds, from: view)
            if frame.intersects(clip) { frames[id] = frame }
        }
        return frames
    }

    /// Pins `d` in the long list scrolled to `offset` (a reachable scroll: the clip at `offset(rowFrame, maxOffset)`)
    /// with the Pinned block out of view, and checks what a person sees, in the clip: `d` starts where its row was drawn
    /// and moves toward the block, every row in view starts where it was drawn and ends on its new slot with no jump, and
    /// the clip does not move again after the reload (no later clamp). Returns `d`'s row pitch and each row's on-screen
    /// move (its rest in the clip after, less its rest in the clip before) for the caller's own rule.
    func pinScrolled(_ name: String, offset: (CGRect, CGFloat) -> CGFloat) throws -> (pitch: CGFloat, moved: [WorkspaceID: CGFloat], failures: [String]) {
        let (list, scroll, window) = Self.scrolledList(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let row = try #require(list.displayed.row(for: .workspace(Self.moved)).map { list.frame(for: $0) })
        let next = try #require(list.displayed.row(for: .workspace(WorkspaceID("e"))).map { list.frame(for: $0) })
        let clipHeight = scroll.contentView.bounds.height
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset(row, list.frame.height - clipHeight)))
        scroll.reflectScrolledClipView(scroll.contentView)
        list.realizeVisibleRows()
        list.layoutSubtreeIfNeeded()
        let clipBefore = scroll.contentView.bounds
        let start = try #require(list.rowViews[.workspace(Self.moved)], "d's row has no view after the scroll")
        let startFrame = list.convert(start.bounds, from: start)
        #expect(startFrame.intersects(clipBefore), "the fixture's d \(startFrame) is out of view \(clipBefore)")
        let blockRow = try #require(list.displayed.row(for: .block(SidebarLayoutDocument.pinnedSectionID.rawValue)))
        #expect(!list.frame(for: blockRow).intersects(clipBefore), "the fixture's Pinned block is in view")
        let before = Self.inView(list, clip: clipBefore)
        #expect(before.count >= 8, "the fixture shows only \(before.count) rows")
        Self.show([Self.moved], listed: Self.long, on: list)
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let clipAfter = scroll.contentView.bounds.minY
        // In the list after the reload, the clip-relative (on-screen) start of anything drawn before it.
        let dy = clipAfter - clipBefore.minY
        let probes = Self.probes(Self.moved, list, now: now)
        let others = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, Self.probes($0, list, now: now)) })
        let after = Dictionary(uniqueKeysWithValues: before.keys.compactMap { id in
            list.rowViews[.workspace(id)].map { (id, list.convert($0.bounds, from: $0)) }
        })
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { $0 is SidebarItemRowView && !$0.isHiddenOrHasHiddenAncestor },
                                   "the pinned item has no view: the row vanished")
        var failures: [String] = []
        Self.checkOpaque("pinned d (\(name))", arrived, failures: &failures)
        Self.checkPath("pinned d (\(name))", probes: probes, now: now, start: startFrame.offsetBy(dx: 0, dy: dy),
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        var moved: [WorkspaceID: CGFloat] = [:]
        for (id, from) in before {
            guard let to = after[id], let probes = others[id] else { failures.append("\(id.rawValue) (\(name)) is gone"); continue }
            Self.checkPath("\(id.rawValue) (\(name))", probes: probes, now: now, start: from.offsetBy(dx: 0, dy: dy), end: to, failures: &failures)
            moved[id] = to.minY - from.minY - dy
        }
        // AppKit's own passes after the reload (layout, the scroller's reflect, a run loop turn) must not move the clip:
        // a list that the reload left taller or shorter than its rows would be clamped there, in a later frame.
        list.layoutSubtreeIfNeeded()
        scroll.reflectScrolledClipView(scroll.contentView)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        if abs(scroll.contentView.bounds.minY - clipAfter) > 0.25 {
            failures.append("\(name): the clip moved again after the reload, \(clipAfter) -> \(scroll.contentView.bounds.minY)")
        }
        if abs(list.frame.height - max(list.displayed.totalHeight, clipHeight)) > 0.25 {
            failures.append("\(name): the list is \(list.frame.height) pt, its rows \(list.displayed.totalHeight) pt")
        }
        return (next.minY - row.minY, moved, failures)
    }

    /// Pin `d` while the Pinned block is scrolled out of view above: the row moves from its slot toward the block and
    /// slides out of view, one copy on every tick; it must not vanish because the block has no view. The block grows
    /// above the clip, so the list keeps what the person sees (ListViewport V5, scroll anchoring): the clip follows the
    /// rows the block pushed down, the rows above `d` stay still on screen, the rows below it close its slot. Before
    /// (d16ad95) this test read the anchor's clip move (660 -> 682) as the pin scrolling the list and the flight's start
    /// in the list's own coordinates (938 vs 916) as a 22 pt jump; on screen both are 0 pt.
    @Test func aPinToABlockOutOfViewSlidesOutOfView() throws {
        // A scroll a person can reach, with room for the anchor below the list's end (the new end is 2 pt shorter).
        let result = try pinScrolled("block out of view") { row, maxOffset in min(row.minY - 100, maxOffset - row.height) }
        var failures = result.failures
        let slot = try #require(Self.long.firstIndex(of: Self.moved))
        for (id, dy) in result.moved {
            let below = (Self.long.firstIndex(of: id) ?? 0) > slot
            if !below, abs(dy) > 0.5 { failures.append("\(id.rawValue) above d moved \(dy) pt on screen (the anchor holds it)") }
            if below, abs(dy + result.pitch) > 0.5 { failures.append("\(id.rawValue) below d moved \(dy) pt on screen, not up one row (\(result.pitch) pt)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    /// Pin `d` with the list scrolled to its end: the pin makes the list 2 pt shorter than the clip's reach, so the list
    /// stays at its end (the clamp the anchor applies with the rows, in the reload's turn, never AppKit's later), the
    /// last row stays still on screen and the rows above `d` close its slot from above. No row in view jumps on any
    /// tick, `d` starts where its row was drawn, and the clip does not move after the reload.
    @Test func aPinWithTheListAtItsEndKeepsTheRowsInViewStill() throws {
        let result = try pinScrolled("list at its end") { _, maxOffset in maxOffset }
        var failures = result.failures
        let slot = try #require(Self.long.firstIndex(of: Self.moved))
        for (id, dy) in result.moved {
            let below = (Self.long.firstIndex(of: id) ?? 0) > slot
            if below, abs(dy) > 0.5 { failures.append("\(id.rawValue) below d moved \(dy) pt on screen (the list's end holds it)") }
            if !below, abs(dy - result.pitch) > 0.5 { failures.append("\(id.rawValue) above d moved \(dy) pt on screen, not down one row (\(result.pitch) pt)") }
        }
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    /// Reduce Motion (the gate off): the pin shows its final state in one frame, with no move on any copy.
    @Test func withoutMotionThePinIsFinalAtOnce() throws {
        let (list, window) = Self.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        Self.show([Self.moved], on: list)
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let end = list.convert(arrived.bounds, from: arrived)
        switch Self.one(probes, at: now) {
        case let .success(frame): #expect(frame.equalTo(end), "first frame \(frame), the slot \(end)")
        case let .failure(failure): Issue.record("first frame: \(failure.text)")
        }
        #expect(probes.allSatisfy { !$0.size.moves(after: now) && $0.nodes.allSatisfy { !$0.position.moves(after: now) } },
                "a copy still moves with motion off")
    }

    /// A pin's Pinned item is made in the apply that flies it. AppKit puts a new subview's layer into its superview's
    /// layer only at a later display pass, and Core Animation drops every animation added to the layer before that: in
    /// the app the item's move springs stopped unfinished about one frame in (diag build: didStop finished=false at
    /// +10 ms, no remove call), so the item showed at its Pinned slot at once and never flew. The flight must start on a
    /// layer that is in its superview's layer, and still fly frames later.
    @Test func aNewItemsFlightSurvivesItsLayerJoiningTheTree() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        host.wantsLayer = true
        window.contentView?.addSubview(host)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
        let item = SidebarItemRowView()
        item.frame = NSRect(x: 0, y: 40, width: 200, height: 24)
        host.addSubview(item)
        SidebarDragSpring.fly(item, from: NSRect(x: 6, y: 160, width: 196, height: 24), now: SidebarPinFlight.begin(in: item))
        let layer = try #require(item.layer)
        #expect(layer.superlayer === host.layer, "the flight started on a layer that is not in its superview's layer")
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let moves = (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(SidebarDragSpring.batchKey).position") }
        #expect(!moves.isEmpty, "the new item's move is gone 50 ms in (its keys: \(layer.animationKeys() ?? []))")
    }
}
