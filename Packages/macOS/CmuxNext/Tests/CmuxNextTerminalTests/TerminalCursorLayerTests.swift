import AppKit
import CmuxNextDesign
@testable import CmuxNextTerminal
import CmuxNextWakeups
import IOSurface
import QuartzCore
import Testing

/// The terminal cursor on the render server: Ghostty's present puts the cursor cell on its
/// layer in the frame's own transaction, main takes only the newest cell's blink, the blink runs only through
/// ``LoopVisibility`` while shown and the motion gate allows blinks, follows a change of the motion settings at
/// once, and a moved cursor is seen at once.
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

    private nonisolated static func surface(width: Int, height: Int) throws -> TerminalCursorState.Image {
        let surface = try #require(IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4]))
        return TerminalCursorState.Image(surface: surface)
    }

    private func makeImage() throws -> TerminalCursorState.Image { try Self.surface(width: 16, height: 32) }

    /// A cell as Ghostty publishes it at scale 2: 16 x 32 pixel cells after 8 x 4 pixels of padding.
    private nonisolated static func cell(column: Int, row: Int, blinking: Bool = true, visible: Bool = true,
                                         intervalMS: UInt32 = 600, image: TerminalCursorState.Image?) -> TerminalCursorState {
        TerminalCursorState(cell: CGRect(x: 8 + 16 * column, y: 4 + 32 * row, width: 16, height: 32), style: .block,
                            visible: visible, blinking: blinking, blinkIntervalMS: blinking ? intervalMS : 0, image: image)
    }

    private func shown(_ clock: SpinnerClock = SpinnerClock()) -> TerminalCursorLayer {
        let cursor = TerminalCursorLayer(clock: clock)
        cursor.place(in: host.window)
        cursor.setScale(2)
        cursor.setShown(true)
        return cursor
    }

    /// Ghostty's present, then main's turn after it.
    private func publish(_ state: TerminalCursorState, to cursor: TerminalCursorLayer) {
        _ = cursor.presenter.present(state)
        cursor.cellsDidChange()
    }

    /// After a move the cell covers the cursor's cell, measured from the top of the view as Ghostty's frame is, at
    /// any view height, and shows the cell Ghostty rendered.
    @Test func theCellCoversTheCursorCellAfterAMove() throws {
        let cursor = shown()
        let surfaceLayer = CALayer()
        surfaceLayer.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
        surfaceLayer.contentsScale = 2
        cursor.install(on: surfaceLayer)
        let image = try makeImage()
        publish(Self.cell(column: 0, row: 0, image: image), to: cursor)
        #expect(cursor.cell.frame == CGRect(x: 4, y: 2, width: 8, height: 16))
        #expect(surfaceLayer.convert(cursor.cell.frame, from: cursor.container) == CGRect(x: 4, y: 82, width: 8, height: 16),
                "the cell is not measured from the top of the view")
        #expect((cursor.cell.contents as AnyObject?) === image.surface, "the layer does not show Ghostty's cell")
        #expect(!cursor.cell.isHidden)

        publish(Self.cell(column: 3, row: 2, image: image), to: cursor)
        #expect(cursor.cell.frame == CGRect(x: 28, y: 34, width: 8, height: 16), "the cursor did not follow its cell")

        surfaceLayer.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        cursor.layout(size: CGSize(width: 400, height: 200))
        #expect(surfaceLayer.convert(cursor.cell.frame, from: cursor.container) == CGRect(x: 28, y: 150, width: 8, height: 16),
                "a taller view moved the cell off its row")
    }

    /// Ghostty's present of a frame puts its cursor cell on the layer in that frame's own transaction, on the
    /// presenting thread, before main runs: the text and the cursor over it commit together.
    @Test func theCellAppliesInThePresentingTransaction() async throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        let presenter = cursor.presenter
        let cellImage = try makeImage()
        let frameImage = try Self.surface(width: 800, height: 200)
        let state = Self.cell(column: 5, row: 1, image: cellImage)
        let completion = DispatchQueue(label: "com.cmuxterm.next.test.cursor-present", qos: .userInteractive)
        let seen = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool, CGRect, Bool), Never>) in
            completion.async {
                // As Ghostty's setSurfaceOffMain: one transaction sets the frame, then its cursor cell.
                let surfaceLayer = CALayer()
                CATransaction.begin()
                surfaceLayer.contents = frameImage.surface
                let wakesMain = presenter.present(state)
                let frameSet = (surfaceLayer.contents as AnyObject?) === frameImage.surface
                let cellSet = (presenter.layers.cell.contents as AnyObject?) === cellImage.surface
                let place = presenter.layers.cell.frame
                CATransaction.commit()
                continuation.resume(returning: (frameSet && cellSet, wakesMain, place, presenter.layers.cell.isHidden))
            }
        }
        #expect(seen.0, "the cursor cell did not go on its layer in its frame's transaction")
        #expect(seen.1, "the first cell asked for no main turn")
        #expect(seen.2 == CGRect(x: 44, y: 18, width: 8, height: 16))
        #expect(!seen.3)
        #expect(!cursor.isBlinking, "the blink started before main's turn")
        cursor.cellsDidChange()
        #expect(cursor.isBlinking)
    }

    /// Cells Ghostty presents while main is busy ask for one main turn, which applies the newest cell's blink; no
    /// older cell waits for main.
    @Test func cellsBeforeMainRunsCoalesceToTheNewest() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        let presenter = cursor.presenter
        let image = try makeImage()
        let wakes = [UInt32(100), 200, 300, 450].enumerated().map { column, interval in
            presenter.present(Self.cell(column: column, row: 0, intervalMS: interval, image: image))
        }
        #expect(wakes == [true, false, false, false], "each cell asked for its own main turn: \(wakes)")
        #expect(cursor.cell.frame.minX == 4 + 8 * 3, "the newest cell is not on the layer")

        cursor.cellsDidChange()
        #expect(cursor.blink?.intervalMS == 450, "main applied an older cell's blink")
        let blink = try #require(cursor.container.animation(forKey: TerminalCursorLayer.blinkKey))
        #expect(abs(blink.duration - 0.9) < 1e-9, "the blink is not the newest cell's: \(blink.duration)")
        #expect(presenter.takeBlink() == nil, "a second main turn would apply the cells again")
        #expect(presenter.present(Self.cell(column: 0, row: 1, image: image)), "a cell after main's turn asked for no main turn")
    }

    /// A blinking cursor runs one discrete opacity loop at Ghostty's interval while shown, and none while its view
    /// is hidden, its window occluded or it is in no window.
    @Test func theBlinkRunsOnlyWhileTheCursorIsShown() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        publish(Self.cell(column: 1, row: 1, image: try makeImage()), to: cursor)
        #expect(cursor.isBlinking)
        let blink = try #require(cursor.container.animation(forKey: TerminalCursorLayer.blinkKey) as? CAKeyframeAnimation)
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
        let image = try makeImage()
        publish(Self.cell(column: 0, row: 0, image: image), to: cursor)
        #expect(!cursor.isBlinking, "Reduce Motion lets the cursor blink")
        #expect(cursor.container.opacity == 1)
        #expect(!cursor.cell.isHidden)

        Motion.reduceMotionOverride = false
        publish(Self.cell(column: 0, row: 0, blinking: false, image: image), to: cursor)
        #expect(!cursor.isBlinking, "a steady cursor (blink off, unfocused, preedit) blinks")
        #expect(cursor.container.animation(forKey: TerminalCursorLayer.blinkKey) == nil)
    }

    /// A blinking cursor follows a change of the motion settings at once, with no new cell: Reduce Motion on
    /// stops the blink and shows the cursor; off again, the blink comes back.
    @Test func aBlinkingCursorFollowsAMotionChangeWithNoNewCell() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        publish(Self.cell(column: 2, row: 1, image: try makeImage()), to: cursor)
        #expect(cursor.isBlinking)

        Motion.reduceMotionOverride = true
        #expect(!cursor.isBlinking, "Reduce Motion turned on while the cursor blinks, and it keeps blinking")
        #expect(cursor.container.opacity == 1)
        #expect(cursor.container.animation(forKey: TerminalCursorLayer.blinkKey) == nil)

        Motion.reduceMotionOverride = false
        #expect(cursor.isBlinking, "Reduce Motion turned off, and the cursor stays steady until it moves")
    }

    /// A blink that starts (the cursor moved, or showed again) begins shown, whatever the shared clock's phase.
    @Test func aMovedCursorIsSeenAtOnce() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let clock = SpinnerClock(mediaTime: { 100 }, unixTime: { 1_000.9 })
        let cursor = shown(clock)
        publish(Self.cell(column: 2, row: 0, image: try makeImage()), to: cursor)
        let blink = try #require(cursor.container.animation(forKey: TerminalCursorLayer.blinkKey))
        let local = (100 - blink.beginTime + blink.timeOffset).truncatingRemainder(dividingBy: blink.duration)
        #expect(min(local, blink.duration - local) < 1e-6, "the blink starts \(local) s into its cycle, maybe hidden")
    }

    /// A cursor the program hides, or one with no rendered cell, shows nothing and blinks nothing.
    @Test func aHiddenCursorShowsNothing() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let cursor = shown()
        publish(Self.cell(column: 0, row: 0, visible: false, image: try makeImage()), to: cursor)
        #expect(cursor.cell.isHidden)
        #expect(!cursor.isBlinking)
        publish(Self.cell(column: 0, row: 0, image: nil), to: cursor)
        #expect(cursor.cell.isHidden)
        #expect(!cursor.isBlinking)
    }

    /// The cursor is a sublayer over Ghostty's content.
    @Test func theCursorSitsOverTheSurfaceLayer() {
        let surfaceLayer = CALayer()
        surfaceLayer.contentsScale = 2
        let cursor = TerminalCursorLayer()
        cursor.install(on: surfaceLayer)
        #expect(cursor.container.superlayer === surfaceLayer)
        #expect(cursor.cell.superlayer === cursor.container)
        #expect(cursor.container.zPosition > 0)
        #expect(cursor.cell.contentsScale == 2)
        #expect(TerminalCursorLayer.subviewZPosition > TerminalCursorLayer.zPosition)
    }
}
