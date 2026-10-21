import AppKit
import Testing
@testable import MessagesLabSidebar

/// PIN-DRAG MOTION (user 2026-10-20, a recording of a row dragged up to the pinned avatars and
/// then down the list: "animations here need to be a lot more fluid"). Messages' pin drag: the
/// lifted avatar leaves the row's avatar (no jump to the pointer), follows the pointer on every
/// event, the rows close the dragged row's place while it is over the grid and open it again
/// when it comes back, the drop springs each row from where it was drawn, and under Reduce
/// Motion nothing animates (the avatar still follows the pointer).
@MainActor
@Suite(.serialized)
struct PinDragMotionTests {
    /// A list with the Chief pinned and seven rows, in an offscreen window.
    @MainActor
    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        var entries: [CmuxSidebarEntry]
        var pinned = ["chief"]
        var controller: SidebarController { view.controller }

        init() {
            let names = ["Chief", "Austin Wang", "Team", "Unii", "Chief 2", "Maya", "Noah", "Ivy"]
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            entries = names.enumerated().map { i, name in
                let id = i == 0 ? "chief" : "c\(i)"
                return CmuxSidebarEntry(id: id, title: name, people: [.init(id: "p\(i)", name: name, initials: String(name.prefix(2)).uppercased())],
                                        preview: "message \(i)", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60),
                                        unreadCount: 0, pinned: i == 0)
            }
            window.contentView = view
            view.onPlacePinned = { [unowned self] id, index in
                pinned.removeAll { $0 == id }
                pinned.insert(id, at: min(index, pinned.count))
                show()
            }
            view.onSetPinned = { [unowned self] pin, id in
                pinned.removeAll { $0 == id }
                if pin { pinned.append(id) }
                show()
            }
            show()
            view.layoutSubtreeIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            controller.document.layoutSubtreeIfNeeded()
            // The first reload tiled against the clip before the window's layout: lay out every row now.
            controller.tile(force: true)
        }

        func show() {
            for i in entries.indices { entries[i].pinned = pinned.contains(entries[i].id) }
            view.show(entries, pinned: pinned)
        }

        /// The visible list rows (not the pinned tiles), top to bottom.
        var rows: [SidebarRowLayer] {
            let tiles = Set(controller.tileLayers.map(ObjectIdentifier.init))
            return (controller.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
                .filter { !tiles.contains(ObjectIdentifier($0)) && !$0.isHidden && $0.conversationID != nil }
                .sorted { $0.frame.minY < $1.frame.minY }
        }

        func row(_ id: String) -> SidebarRowLayer? { rows.first { $0.conversationID == id } }

        /// A point on a row's title (document coordinates).
        func onTitle(of id: String) throws -> CGPoint {
            let l = try #require(row(id))
            return CGPoint(x: l.frame.minX + 150, y: l.frame.midY)
        }
    }

    /// Where the ghost's avatar is drawn when its lift starts: its model place minus any additive
    /// offset still to run, at the scale it starts from.
    private func ghostAvatarCenterAtLift(_ ghost: CALayer, _ metrics: SidebarMetrics) -> CGPoint {
        let tileAvatar = SidebarDraw.tileAvatar(metrics)
        var position = ghost.position
        for key in ghost.animationKeys() ?? [] {
            guard let a = ghost.animation(forKey: key) as? CABasicAnimation else { continue }
            if a.keyPath == "position", a.isAdditive, let from = (a.fromValue as? NSValue)?.pointValue {
                position.x += from.x
                position.y += from.y
            } else if a.keyPath == "position", let from = (a.fromValue as? NSValue)?.pointValue {
                position = from
            }
        }
        var scale = ghost.transform.m11
        for key in ghost.animationKeys() ?? [] {
            if let a = ghost.animation(forKey: key) as? CABasicAnimation, a.keyPath == "transform.scale",
               let from = a.fromValue as? CGFloat ?? (a.fromValue as? NSNumber).map({ CGFloat($0.doubleValue) }) { scale = from }
        }
        let size = ghost.bounds.size
        let o = CGPoint(x: tileAvatar.midX - size.width / 2, y: tileAvatar.midY - size.height / 2)
        return CGPoint(x: position.x + o.x * scale, y: position.y + o.y * scale)
    }

    /// A layer's top without its transform.
    private func top(_ l: CALayer) -> CGFloat { l.position.y - l.bounds.height * l.anchorPoint.y }

    private func cpuMs(_ body: () -> Void) -> Double {
        let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        body()
        return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e6
    }

    /// The lifted avatar starts on the row's avatar, not at the pointer: no jump.
    @Test func aLiftedRowStartsOnItsOwnAvatar() throws {
        CmuxSidebarView.reduceMotionOverride = false
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        let f = Fixture()
        let row = try #require(f.row("c1"))
        let press = try f.onTitle(of: "c1")
        #expect(f.controller.beginPinDrag(at: press))
        let ghost = try #require(f.controller.pinDragState.ghost)
        let rowAvatar = CGPoint(x: f.controller.metrics.rowAvatarX + SidebarMetrics.avatar / 2, y: row.frame.midY)
        let start = ghostAvatarCenterAtLift(ghost, f.controller.metrics)
        print("PINDRAG lift start \(start) row avatar \(rowAvatar)")
        #expect(abs(start.x - rowAvatar.x) < 1.5 && abs(start.y - rowAvatar.y) < 1.5)
        f.controller.cancelPinDrag()
    }

    /// 240 pointer moves (up to the grid, then down the list): the avatar is under the pointer
    /// after every move, no move costs a 120 Hz frame, and the rows retarget: the dragged row's
    /// place closes over the grid and opens again over the list.
    @Test func theLiftedAvatarFollowsEveryMoveAndTheRowsMakeRoom() throws {
        CmuxSidebarView.reduceMotionOverride = false
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        let f = Fixture()
        let start = try f.onTitle(of: "c1")
        let below = try #require(f.row("c2"))
        let rowHeight = top(below) - top(try #require(f.row("c1")))
        #expect(f.controller.beginPinDrag(at: start))
        let ghost = try #require(f.controller.pinDragState.ghost)
        let grid = CGPoint(x: f.controller.tileRect(1).midX, y: f.controller.tileRect(1).midY)
        let down = CGPoint(x: start.x, y: f.controller.rowRect(5).midY)
        var worst = 0.0
        var offsets: Set<String> = []
        var overGridShift: CGFloat?
        for i in 0..<240 {
            let t = CGFloat(i) / 119
            let p = i < 120 ? CGPoint(x: start.x + (grid.x - start.x) * t, y: start.y + (grid.y - start.y) * t)
                : CGPoint(x: grid.x + (down.x - grid.x) * (t - 1), y: grid.y + (down.y - grid.y) * (t - 1))
            worst = max(worst, cpuMs { f.controller.movePinDrag(to: p) })
            let g = f.controller.pinDragState.grab
            let off = CGPoint(x: ghost.position.x - (p.x - g.width), y: ghost.position.y - (p.y - g.height))
            offsets.insert(String(format: "%.2f,%.2f", off.x, off.y))
            if i == 119 { overGridShift = below.transform.m42 }
        }
        print("PINDRAG worst move cpu \(String(format: "%.2f", worst)) ms, offsets \(offsets)")
        #expect(offsets == ["0.00,0.00"])
        #expect(worst < 1000 / 120)
        // Over the grid: one more tile fits in the Chief's row (no new grid row), so the rows
        // below the dragged one only close its place.
        let gridGrowth = f.controller.metrics.pinnedHeight(count: 2) - f.controller.metrics.pinnedHeight(count: 1)
        #expect(overGridShift == gridGrowth - rowHeight)
        #expect(f.row("c2")?.transform.m42 == 0)
        f.controller.cancelPinDrag()
    }

    /// The drop pins the row: every row below springs from where it was drawn to its new place.
    @Test func theDropSpringsEachRowFromWhereItWasDrawn() throws {
        CmuxSidebarView.reduceMotionOverride = false
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        let f = Fixture()
        #expect(f.controller.beginPinDrag(at: try f.onTitle(of: "c1")))
        let tile = f.controller.tileRect(1)
        f.controller.movePinDrag(to: CGPoint(x: tile.midX, y: tile.midY))
        // The rows settle where the preview put them (no spring still running), then the drop.
        for l in f.rows { l.removeAllAnimations() }
        CATransaction.flush()
        let drawn = Dictionary(uniqueKeysWithValues: f.rows.compactMap { l in l.conversationID.map { ($0, top(l) + l.transform.m42) } })
        f.controller.endPinDrag()
        #expect(f.pinned == ["chief", "c1"])
        let all = (f.controller.document.layer?.sublayers ?? []).compactMap { $0 as? SidebarRowLayer }
        print("PINDRAG drop rows \(f.rows.map { $0.conversationID ?? "-" }) drawn \(drawn.keys.sorted()) "
              + "layers \(all.map { "\($0.conversationID ?? "-")\($0.isHidden ? "h" : "")@\(Int($0.frame.minY))" }) "
              + "clip \(f.controller.scrollView.contentView.bounds)")
        var checked = 0
        for l in f.rows {
            guard let id = l.conversationID, let was = drawn[id] else { continue }
            let a = l.animation(forKey: "cmux.pinDrag.shift") as? CABasicAnimation
            let from = (a?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            #expect(abs(top(l) + from - was) < 0.5, "row \(id) starts at \(top(l) + from), was drawn at \(was)")
            checked += 1
        }
        #expect(checked >= 4)
    }

    /// Reduce Motion: the avatar follows the pointer, and nothing else animates.
    @Test func reduceMotionDragsWithNoAnimation() throws {
        CmuxSidebarView.reduceMotionOverride = true
        defer { CmuxSidebarView.reduceMotionOverride = nil }
        let f = Fixture()
        #expect(f.controller.beginPinDrag(at: try f.onTitle(of: "c1")))
        let ghost = try #require(f.controller.pinDragState.ghost)
        var animated: [String] = []
        func collect() {
            animated += (ghost.animationKeys() ?? []).map { "ghost:\($0)" }
            for l in f.rows + f.controller.tileLayers { animated += (l.animationKeys() ?? []).map { "\(l.conversationID ?? "-"):\($0)" } }
        }
        collect()
        let tile = f.controller.tileRect(1)
        for i in 0...20 {
            let t = CGFloat(i) / 20
            f.controller.movePinDrag(to: CGPoint(x: 170 + (tile.midX - 170) * t, y: 300 + (tile.midY - 300) * t))
            collect()
        }
        f.controller.endPinDrag()
        collect()
        #expect(animated.isEmpty, "\(Set(animated))")
    }
}
