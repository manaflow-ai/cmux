import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// RESIZE P0 7 cause M2 (px-keys-held-2-s1r, cmux21 120 Hz 1x, build fe0d956f, frames.json marks): in each spring frame
/// of a keyboard resize the window's frame view (`NSThemeFrame`) lays out 1-2 times. The mark stacks:
/// `TerminalSurfaceView.setFrameSize` / `PaneHostView.setFrameSize` -> `-[NSView setFrameSize:]` ->
/// `NSViewUpdateConstraintsForFrameChange` -> `_updateSimpleAutoresizingConstraintsInPlace:` -> the frame view's
/// `needsLayout`, so the CA commit's `-[NSWindow layoutIfNeeded]` runs a window pass in every spring frame. Chrome's
/// views place their children by frame and lay out only the boxes whose size changed.
///
/// The rule: with a terminal in each pane, a spring frame's window pass (`NSWindow.layoutIfNeeded`, as the CA commit runs
/// it) lays out no view whose size did not change in that frame: in particular not the window's frame view.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SpringFrameNoWindowPassTests {
    typealias Ground = PaneGroundCoversPaneTests
    typealias Counts = KeyResizeLayoutsPerFrameTests

    /// The views of `window` that take part in Auto Layout (own constraints, or not translating their autoresizing mask).
    static func constraintViews(in window: NSWindow) -> String {
        var found: [String] = []
        var stack = [window.contentView?.superview].compactMap { $0 }
        while let view = stack.popLast() {
            let own = view.constraints.count
            if own > 0 || !view.translatesAutoresizingMaskIntoConstraints {
                found.append("\(type(of: view))(c\(own)\(view.translatesAutoresizingMaskIntoConstraints ? "" : " noAR") in \(view.superview.map { "\(type(of: $0))" } ?? "-"))")
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.prefix(24).joined(separator: ", ")
    }

    @Test(arguments: [LayoutDirection.left, .right])
    func aKeyResizeSpringFrameRunsNoWindowPass(direction: LayoutDirection) throws {
        LayoutPassGuard.shared.install()
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        let frameView = try #require(rig.window.contentView?.superview)
        let frameClass = String(describing: type(of: frameView))
        rig.root.layoutSubtreeIfNeeded()
        rig.commit()
        rig.window.layoutIfNeeded()

        #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
        rig.window.layoutIfNeeded() // the key's turn: its own commit
        var extra: [String] = []
        var framePasses = 0
        var frames = 0
        while frames < 240 {
            let before = Counts.sizes(under: frameView)
            let moving = rig.frame()
            // The CA commit at the end of the frame's turn: AppKit's window pass.
            let start = Counts.calls()
            rig.window.layoutIfNeeded()
            let laid = Counts.since(start)
            frames += 1
            var resized: [String: Int] = [:]
            for (id, entry) in Counts.sizes(under: frameView) where before[id]?.size != entry.size { resized[entry.viewClass, default: 0] += 1 }
            framePasses += laid[frameClass, default: 0]
            for (viewClass, count) in laid where count > resized[viewClass, default: 0] {
                extra.append("frame \(frames): \(viewClass) \(count)x (\(resized[viewClass, default: 0]) resized)")
            }
            if !moving { break }
        }
        #expect(frames > 2, "the press did not spring")
        #expect(framePasses == 0, "the window's frame view (\(frameClass)) laid out \(framePasses)x in \(frames) spring frames. Auto Layout views: \(Self.constraintViews(in: rig.window))")
        #expect(extra.isEmpty, "\(extra.count) window-pass layouts of views whose size did not change: \(extra.prefix(16))")
    }
}
