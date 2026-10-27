import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import IOSurface
import QuartzCore
import Testing

/// The terminal cursor on the render server (p03-rendering-091): the cursor layer sits on the cell Ghostty
/// published, blinks only through ``LoopVisibility`` while shown and the motion gate allows blinks, and a moved
/// cursor is seen at once.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalCursorLayerTests {
    /// A window whose visibility the test sets (no screen needed).
    final class Host {
        var state: Visibility = .visible
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        private(set) var source: WindowVisibilitySource!

        init() {
            window.isReleasedWhenClosed = false
            source = WindowVisibilitySource.of(window, name: "cursorTestWindow") { [unowned self] _ in self.state }
        }

        func set(_ state: Visibility) {
            self.state = state
            source.refresh()
        }
    }

    /// The cursor's window, alive for the test.
    let host = Host()

    private func cell() throws -> TerminalCursorState.Image {
        let surface = try #require(IOSurface(properties: [.width: 16, .height: 32, .bytesPerElement: 4]))
        return TerminalCursorState.Image(surface: surface)
    }

    private func cursor(column: Int, row: Int, blinking: Bool = true, visible: Bool = true,
                        image: TerminalCursorState.Image?) -> TerminalCursorState {
        TerminalCursorState(cell: CGRect(x: 4 + 8 * column, y: 2 + 16 * row, width: 8, height: 16), style: .block,
                            visible: visible, blinking: blinking, blinkInterval: 0.6, image: image)
    }

    private func shown(_ clock: SpinnerClock = SpinnerClock()) -> TerminalCursorLayer {
        let cursor = TerminalCursorLayer(clock: clock)
        cursor.place(in: host.window)
        cursor.setShown(true)
        return cursor
    }

    /// After a move the layer covers the cursor's cell, measured from the top of the view as Ghostty's frame is,
    /// and shows the cell Ghostty rendered.
    @Test func theLayerCoversTheCursorCellAfterAMove() throws {
        let cursor = shown()
        let image = try cell()
        cursor.show(self.cursor(column: 0, row: 0, image: image), viewHeight: 100)
        #expect(cursor.layer.frame == CGRect(x: 4, y: 82, width: 8, height: 16))
        #expect((cursor.layer.contents as AnyObject?) === image.surface, "the layer does not show Ghostty's cell")
        #expect(!cursor.layer.isHidden)

        cursor.show(self.cursor(column: 3, row: 2, image: image), viewHeight: 100)
        #expect(cursor.layer.frame == CGRect(x: 28, y: 50, width: 8, height: 16), "the cursor did not follow its cell")

        cursor.layout(viewHeight: 200)
        #expect(cursor.layer.frame == CGRect(x: 28, y: 150, width: 8, height: 16), "a taller view moved the cell off its row")
    }

    /// A blinking cursor runs one discrete opacity loop at Ghostty's interval while shown, and none while its view
    /// is hidden, its window occluded or it is in no window.
    @Test func theBlinkRunsOnlyWhileTheCursorIsShown() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        cursor.show(self.cursor(column: 1, row: 1, image: try cell()), viewHeight: 100)
        #expect(cursor.isBlinking)
        let blink = try #require(cursor.layer.animation(forKey: TerminalCursorLayer.blinkKey) as? CAKeyframeAnimation)
        #expect(blink.keyPath == "opacity")
        #expect(blink.calculationMode == .discrete, "a blink fades instead of stepping")
        #expect(blink.values as? [Int] == [1, 0])
        #expect(abs(blink.duration - 1.2) < 1e-9, "one blink is shown 0.6 s, hidden 0.6 s: \(blink.duration)")
        #expect(blink.repeatCount == .infinity)

        cursor.setShown(false)
        #expect(!cursor.isBlinking, "a hidden terminal's cursor keeps blinking")
        cursor.setShown(true)
        #expect(cursor.isBlinking)
        host.set(.occluded)
        #expect(!cursor.isBlinking, "an occluded window's cursor keeps blinking")
        host.set(.visible)
        #expect(cursor.isBlinking)
        cursor.place(in: nil)
        #expect(!cursor.isBlinking, "a cursor out of its window keeps blinking")
    }

    /// Reduce Motion, or a cursor that does not blink, holds the cursor steady and shown.
    @Test func reduceMotionOrNoBlinkKeepsTheCursorSteady() throws {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        let image = try cell()
        cursor.show(self.cursor(column: 0, row: 0, image: image), viewHeight: 100)
        #expect(!cursor.isBlinking, "Reduce Motion lets the cursor blink")
        #expect(cursor.layer.opacity == 1)
        #expect(!cursor.layer.isHidden)

        Motion.reduceMotionOverride = false
        cursor.show(self.cursor(column: 0, row: 0, blinking: false, image: image), viewHeight: 100)
        #expect(!cursor.isBlinking, "a steady cursor (blink off, unfocused, preedit) blinks")
        #expect(cursor.layer.animation(forKey: TerminalCursorLayer.blinkKey) == nil)
    }

    /// A blink that starts (the cursor moved, or showed again) begins shown, whatever the shared clock's phase.
    @Test func aMovedCursorIsSeenAtOnce() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let clock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.9 })
        let cursor = shown(clock)
        cursor.show(self.cursor(column: 2, row: 0, image: try cell()), viewHeight: 100)
        let blink = try #require(cursor.layer.animation(forKey: TerminalCursorLayer.blinkKey))
        let local = (100 - blink.beginTime + blink.timeOffset).truncatingRemainder(dividingBy: blink.duration)
        #expect(min(local, blink.duration - local) < 1e-6, "the blink starts \(local) s into its cycle, maybe hidden")
    }

    /// A cursor the program hides, or one with no rendered cell, shows nothing and blinks nothing.
    @Test func aHiddenCursorShowsNothing() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        cursor.show(self.cursor(column: 0, row: 0, visible: false, image: try cell()), viewHeight: 100)
        #expect(cursor.layer.isHidden)
        #expect(!cursor.isBlinking)
        cursor.show(self.cursor(column: 0, row: 0, image: nil), viewHeight: 100)
        #expect(cursor.layer.isHidden)
        #expect(!cursor.isBlinking)
    }

    /// The cursor is a sublayer over Ghostty's content.
    @Test func theCursorSitsOverTheSurfaceLayer() {
        let host = CALayer()
        host.contentsScale = 2
        let cursor = TerminalCursorLayer()
        cursor.install(on: host)
        #expect(cursor.layer.superlayer === host)
        #expect(cursor.layer.zPosition > 0)
        #expect(cursor.layer.contentsScale == 2)
        #expect(TerminalCursorLayer.subviewZPosition > TerminalCursorLayer.zPosition)
    }
}
