import CmuxNextCompat
import CoreGraphics
import Testing

/// SECURITY (cmux#37286): the list every capture cmux makes reads to leave out a window only the person
/// may see. A capture follows it at once: each change reaches its observers, and only a change does.
struct CaptureExcludedWindowsTests {
    /// The changes an observer heard (every call here runs on the test's own thread).
    final class Heard: @unchecked Sendable {
        var count = 0
    }

    @Test func aWindowStaysOutUntilItsOwnerRemovesItAndEveryChangeIsHeard() {
        let list = CaptureExcludedWindows()
        let heard = Heard()
        var observation: CaptureExcludedWindows.Observation? = list.observe { heard.count += 1 }
        list.insert(42)
        list.insert(42)
        list.insert(0) // no window number yet: nothing to leave out
        #expect(list.windowIDs == [42])
        #expect(heard.count == 1, "only a change is heard")
        list.remove(42)
        list.remove(42)
        #expect(list.windowIDs.isEmpty)
        #expect(heard.count == 2)
        #expect(observation != nil)
        observation = nil
        list.insert(7)
        #expect(heard.count == 2, "a released observation hears nothing")
    }
}
