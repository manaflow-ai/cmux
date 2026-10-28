@testable import CmuxNextApp
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import Testing

/// The app owners that moved from an AppKit local monitor to the input tap hear
/// exactly the types of the monitor mask they had, through `observe(types:)`.
@MainActor struct InputTapMaskTests {
    /// Every ``InputEventType``.
    static let allTypes: [InputEventType] = [
        .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
        .otherMouseUp, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
        .magnify, .rotate, .swipe, .smartMagnify, .pressure, .mouseEntered, .mouseExited,
    ]

    /// What one subscription heard.
    final class Heard {
        var types: [InputEventType] = []
    }

    /// The types a subscription for `types` hears when every type is delivered once.
    func heard(_ types: InputEventTypes) -> (types: [InputEventType], classes: InputEventClasses) {
        let tap = FakeInputTap()
        let heard = Heard()
        let subscription = tap.observe(types: types) { heard.types.append($0.type) }
        for type in Self.allTypes { tap.deliver(InputEventRecord(type: type, timestamp: 1)) }
        let classes = tap.classes
        subscription.cancel()
        return (heard.types, classes)
    }

    /// The busy watchdog's input, the magnify and swipe gestures included.
    @Test func theWatchdogHearsItsOldMaskGesturesIncluded() {
        let (types, classes) = heard(AppControl.activityInput)
        #expect(types == [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged,
                          .rightMouseDragged, .scrollWheel, .magnify, .swipe])
        #expect(classes == [.key, .button, .pointerMove, .drag, .scroll, .gesture])
    }

    /// The New Tab spare's warm waits on key-downs, left and right clicks and scrolls only.
    @Test func theSpareWarmHearsItsOldMask() {
        let (types, classes) = heard(NewTabPreload.warmDelayingInput)
        #expect(types == [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel])
        #expect(classes == [.key, .button, .scroll])
    }
}
