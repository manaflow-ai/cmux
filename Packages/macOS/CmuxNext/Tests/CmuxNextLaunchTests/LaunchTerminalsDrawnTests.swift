import CmuxNextLaunch
import Testing

/// `launch.visible_terminals_drawn` (bench_launch.py `after-kill`) comes when every visible terminal
/// drew the frame after its first content, never when the content was only queued: a pane counts as loaded at the
/// queue, before the parse, the draw and the reveal of a pane held clear.
@MainActor
struct LaunchTerminalsDrawnTests {
    @Test func contentQueuedWithNoFrameDrawnGivesNoMark() {
        let f = DrawnFixture()
        f.queue(f.a)
        f.queue(f.b)
        f.drawn.whenDrawn([f.key(f.a), f.key(f.b)]) { f.marks += 1 }
        #expect(f.marks == 0, "the terminals' content is queued but no frame showed it")
        f.draw(f.a)
        #expect(f.marks == 0, "one terminal still shows no screen")
        f.draw(f.b)
        #expect(f.marks == 1)
        f.draw(f.b)
        #expect(f.marks == 1, "the mark comes once")
        #expect(f.cancelled == 2, "every wait ends with the mark")
    }

    /// A terminal that drew before the panes all loaded counts: its wait began at its own content.
    @Test func aFrameDrawnBeforeTheWaitBeganCounts() {
        let f = DrawnFixture()
        f.queue(f.a)
        f.draw(f.a)
        f.drawn.whenDrawn([f.key(f.a)]) { f.marks += 1 }
        #expect(f.marks == 1)
    }

    @Test func aTerminalWhoseContentNeverQueuedHoldsTheMark() {
        let f = DrawnFixture()
        f.queue(f.a)
        f.draw(f.a)
        f.drawn.whenDrawn([f.key(f.a), f.key(f.b)]) { f.marks += 1 }
        #expect(f.marks == 0)
    }

    @Test func eachTerminalIsWatchedOnceAndNoneAfterTheEnd() {
        let f = DrawnFixture()
        f.queue(f.a)
        f.queue(f.a)
        #expect(f.watches == 1)
        f.drawn.stop()
        #expect(f.cancelled == 1)
        f.queue(f.b)
        #expect(f.watches == 1, "a stopped launch starts no wait")
        f.drawn.whenDrawn([f.key(f.b)]) { f.marks += 1 }
        #expect(f.marks == 0)
    }

    @Test func noTerminalOnScreenGivesNoMark() {
        let f = DrawnFixture()
        f.drawn.whenDrawn([]) { f.marks += 1 }
        #expect(f.marks == 0, "there is no terminal screen to time")
        #expect(!f.drawn.isFinished)
    }
}

/// Two terminals whose frames the test draws by hand.
@MainActor
private final class DrawnFixture {
    final class Terminal {}

    let drawn = LaunchTerminalsDrawn()
    let a = Terminal(), b = Terminal()
    var marks = 0, watches = 0, cancelled = 0
    private var waits: [ObjectIdentifier: @MainActor () -> Void] = [:]

    func key(_ terminal: Terminal) -> ObjectIdentifier { ObjectIdentifier(terminal) }

    /// The terminal's first content was queued on its lane.
    func queue(_ terminal: Terminal) {
        drawn.contentQueued(key(terminal)) { [self] frame in
            watches += 1
            waits[key(terminal)] = frame
            return { [self] in cancelled += 1 }
        }
    }

    /// The terminal drew its first frame after its content.
    func draw(_ terminal: Terminal) {
        waits[key(terminal)]?()
    }
}
