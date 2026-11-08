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
    static func state(_ pins: [WorkspaceID]) -> (sections: [SidebarSection], blocks: SidebarListBlocks) {
        let pinned = [anchor] + pins
        let items = pinned.map { LayoutItem(id: LayoutItemID("itm_pin_\($0.rawValue)"), ref: .workspace($0.rawValue)) }
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let section = SidebarLayoutDocument.pinnedSection(items: items)
        var infos = [home.id: SidebarItemInfo.fallback(for: home)]
        for (item, workspace) in zip(items, pinned) {
            var info = SidebarItemInfo(title: workspace.rawValue, symbol: "terminal")
            info.workspace = workspace
            infos[item.id] = info
        }
        let sections = [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: section.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: listed.filter { !pinned.contains($0) }
                .map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ]
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        let blocks = SidebarListBlocks(sections: [top.id.rawValue: top, section.id.rawValue: section], infos: infos, collapsed: [],
                                       look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        return (sections, blocks)
    }

    /// The list shows `pins` pinned (the sidebar's blocks and rows change together, as the app's pin does).
    static func show(_ pins: [WorkspaceID], on list: SidebarListView) {
        let (sections, blocks) = state(pins)
        list.blocks = blocks
        list.model.sections = sections
    }

    static func list(pins: [WorkspaceID]) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let (sections, blocks) = state(pins)
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
            return .failure(Failure(text: "\(shown.count) copies show: \(shown.map { "\($0.frame) at \($0.opacity)" })"))
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

    /// Pins or unpins `d` with motion and checks its path and every other workspace's.
    func move(pin: Bool) throws {
        let (list, window) = Self.list(pins: pin ? [] : [Self.moved])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        let before = Self.rest(list)
        Self.show(pin ? [Self.moved] : [], on: list)
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let others = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, Self.probes($0, list, now: now)) })
        let after = Self.rest(list)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkPath(pin ? "pinned d" : "unpinned d", probes: probes, now: now, start: startFrame,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        for (id, from) in before {
            guard let to = after[id], let probes = others[id] else { failures.append("\(id.rawValue) is gone"); continue }
            Self.checkPath(id.rawValue, probes: probes, now: now, start: from, end: to, failures: &failures)
        }
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
    }

    @Test func aPinMovesTheRowToItsPinnedSlot() throws { try move(pin: true) }

    @Test func anUnpinMovesTheItemBackToItsRow() throws { try move(pin: false) }

    /// The app's pin reaches the list in two updates: the rows (the workspace leaves the list), then a frame later the
    /// blocks (the Pinned item). The row stays where it is drawn until the item takes over its frame, then moves.
    @Test func aPinWhoseBlockComesLaterStartsOnTheRow() throws { try blockComesLater(pinStateWithTheRows: true) }

    /// The app's document pin state comes with the blocks: at the rows' update the workspace is not pinned yet, its row
    /// starts to close, and the block's item then flies from where the closing row is drawn (no wait at the key).
    @Test func aPinWhoseStateComesWithTheBlockStartsOnTheClosingRow() throws { try blockComesLater(pinStateWithTheRows: false) }

    func blockComesLater(pinStateWithTheRows: Bool) throws {
        let (list, window) = Self.list(pins: [])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var pinnedNow = pinStateWithTheRows
        list.model.workspacePin = (isPinned: { pinnedNow && $0 == Self.moved }, toggle: { _ in })
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        let (sections, blocks) = Self.state([Self.moved])
        list.model.sections = sections
        list.reload(animated: true)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        // Where the person sees the workspace when the block comes: the held or the closing row, as drawn.
        let drawnRow = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let drawnStart = pinStateWithTheRows ? startFrame : list.drawnFrame(of: drawnRow)
        pinnedNow = true
        list.blocks = blocks
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkPath("pinned d (rows first)", probes: probes, now: now, start: drawnStart,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
        #expect(failures.isEmpty, "\(failures.prefix(16).joined(separator: "\n"))")
        #expect(list.pinHolds.isEmpty, "the row still waits after its block came")
    }

    /// The app delivers an unpin's blocks a frame or two before its rows: the item stays where it is drawn until the
    /// row comes, and the row then moves from it (no vanish, no grow-in at the row's slot).
    @Test func anUnpinWhoseRowComesLaterStartsOnTheItem() throws {
        let (list, window) = Self.list(pins: [Self.moved])
        defer { window.close() }
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        list.model.workspacePin = (isPinned: { _ in false }, toggle: { _ in })
        let start = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        let startFrame = list.convert(start.bounds, from: start)
        let (sections, blocks) = Self.state([])
        list.blocks = blocks
        list.reload(animated: true)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        #expect(!Self.copies(of: Self.moved, in: list).filter { !$0.isHiddenOrHasHiddenAncestor }.isEmpty,
                "the item vanished before its row came")
        list.model.sections = sections
        list.reload(animated: true)
        let now = CACurrentMediaTime()
        let probes = Self.probes(Self.moved, list, now: now)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        var failures: [String] = []
        Self.checkPath("unpinned d (blocks first)", probes: probes, now: now, start: startFrame,
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
        // The unpin's moves begin with this reload's transaction: the pin's path (captured before it) at that time is
        // where the person sees the workspace when the unpin starts.
        let now = CACurrentMediaTime()
        var failures: [String] = []
        let drawn: CGRect
        switch Self.one(pinning, at: now) {
        case let .success(frame): drawn = frame
        case let .failure(failure):
            Issue.record("the pin at the unpin: \(failure.text)")
            return
        }
        let probes = Self.probes(Self.moved, list, now: now)
        let arrived = try #require(Self.copies(of: Self.moved, in: list).first { !$0.isHiddenOrHasHiddenAncestor })
        Self.checkPath("unpin over a pin", probes: probes, now: now, start: drawn,
                       end: list.convert(arrived.bounds, from: arrived), failures: &failures)
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
}
