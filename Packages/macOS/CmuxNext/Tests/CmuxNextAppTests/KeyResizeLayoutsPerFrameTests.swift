import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE P0 4 (m50 item 2, cmux21 120 Hz, build ad9c5d17): the frame that holds a keyboard resize press misses its
/// refresh with 10-34 view layouts in it, and every spring frame after it lays out 10-23 views. The Chrome model: a
/// motion frame lays out only the boxes whose size changes; everything else keeps its layout (CLAUDE.md: a layout per
/// animation frame that changes nothing is a bug).
///
/// The rule, counted with `LayoutPassGuard` (`-[NSView layout]` calls per view class): the key's own turn lays nothing
/// out, and in each frame of the spring a view class is laid out at most as many times as views of that class changed
/// size in that frame.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeLayoutsPerFrameTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// Layout calls per view class since launch.
    static func calls() -> [String: Int] {
        Dictionary(LayoutPassGuard.shared.passesByClass.map { ($0.viewClass, $0.passes) }, uniquingKeysWith: +)
    }

    /// Calls per class between `start` and now.
    static func since(_ start: [String: Int]) -> [String: Int] {
        calls().reduce(into: [:]) { result, entry in
            let added = entry.value - (start[entry.key] ?? 0)
            if added > 0 { result[entry.key] = added }
        }
    }

    /// The size of every view under `root` (root included), by identity, with its class name as the guard names it.
    static func sizes(under root: NSView) -> [ObjectIdentifier: (viewClass: String, size: CGSize)] {
        var result: [ObjectIdentifier: (viewClass: String, size: CGSize)] = [:]
        var stack = [root]
        while let view = stack.popLast() {
            result[ObjectIdentifier(view)] = (String(describing: type(of: view)), view.bounds.size)
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    static func text(_ counts: [String: Int]) -> String {
        counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Ctrl-Shift-H, L, K or J on p2 with a terminal in each pane: the key's turn lays out no view, and each frame of the
    /// spring lays out only views whose size changed in it.
    @Test(arguments: [LayoutDirection.left, .right, .up, .down])
    func aResizeMotionLaysOutOnlyTheViewsWhoseSizeChanges(direction: LayoutDirection) throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(direction == .left || direction == .right ? Ground.pair : Ground.stack), focused: "p2")
        defer { rig.close() }
        let root = try #require(rig.window.contentView)
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()

        var start = Self.calls()
        let pressed = ContinuousClock.now
        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        let keyTurnTime = ContinuousClock.now - pressed
        let keyTurn = Self.since(start)
        var extra: [String] = keyTurn.isEmpty ? [] : ["key turn (\(keyTurnTime)): \(Self.text(keyTurn))"]
        var perFrame: [String] = []
        var frames = 0
        while frames < 240 {
            let before = Self.sizes(under: root)
            start = Self.calls()
            let began = ContinuousClock.now
            let moving = rig.frame()
            let took = ContinuousClock.now - began
            frames += 1
            let laid = Self.since(start)
            var resized: [String: Int] = [:]
            for (id, entry) in Self.sizes(under: root) where before[id]?.size != entry.size { resized[entry.viewClass, default: 0] += 1 }
            if frames <= 3 { perFrame.append("frame \(frames) (\(took)): laid out [\(Self.text(laid))], resized [\(Self.text(resized))]") }
            for (viewClass, count) in laid where count > resized[viewClass, default: 0] {
                extra.append("frame \(frames): \(viewClass) laid out \(count)x, \(resized[viewClass, default: 0]) resized")
            }
            if !moving { break }
        }
        #expect(frames > 2, "the press did not spring")
        #expect(extra.isEmpty, "\(extra.count) layouts of views whose size did not change: \(extra.prefix(16)). \(perFrame)")
    }
}
