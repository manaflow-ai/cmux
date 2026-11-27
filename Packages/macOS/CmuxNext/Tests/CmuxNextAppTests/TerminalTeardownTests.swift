import AppKit
@testable import CmuxNextTerminal
import Testing

/// cx-qxxu: Cmd-T's New Tab page withdrew a terminal while its action ran, and the terminal
/// model's deinit hopped to the main actor, which traps under CEF inside an action's task-local
/// scope (cx-t7hu). A deinit with no hop tears the model down on the thread that releases it; one
/// that hops waits for the main actor, which this test keeps busy while another thread releases
/// the last reference.
@MainActor
struct TerminalTeardownTests {
    nonisolated final class Released: @unchecked Sendable {
        var model: TerminalSurfaceModel?
        weak var background: NSColor?
        var tornDown = false
    }

    @Test func aTerminalModelTearsDownOnTheThreadThatReleasesIt() {
        let released = Released()
        autoreleasepool {
            let model = TerminalSurfaceModel()
            let background = NSColor(srgbRed: 0.123, green: 0.456, blue: 0.789, alpha: 1)
            model.backgroundOverride = background
            released.model = model
            released.background = background
        }
        #expect(released.background != nil)
        // The main thread waits here, so a teardown that hops to the main actor cannot run before
        // the other thread looks.
        let checked = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            released.model = nil
            released.tornDown = released.background == nil
            checked.signal()
        }
        checked.wait()
        #expect(released.tornDown, "the model's teardown waited for the main actor")
    }
}
