import AppKit
@testable import CmuxNextApp
import Testing

/// The events whose queueing `CmuxApplication.sendEvent` feeds to the watchdog's input-queueing histogram:
/// the user's keys, clicks and wheel, as Chromium's EventLatency counts them;
/// never moves, modifier changes or the app's synthetic input.
@MainActor @Suite struct CmuxApplicationQueueingTests {
    @Test func keysClicksAndWheelAreMeasured() {
        let measured: [NSEvent.EventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                             .otherMouseDown, .otherMouseUp, .scrollWheel]
        for type in measured {
            #expect(CmuxApplication.measuresQueueing(type, synthetic: false), "\(type.rawValue)")
        }
    }

    @Test func movesModifiersAndSyntheticInputAreNot() {
        for type: NSEvent.EventType in [.mouseMoved, .leftMouseDragged, .flagsChanged, .appKitDefined, .applicationDefined] {
            #expect(!CmuxApplication.measuresQueueing(type, synthetic: false), "\(type.rawValue)")
        }
        for type: NSEvent.EventType in [.keyDown, .leftMouseDown, .scrollWheel] {
            #expect(!CmuxApplication.measuresQueueing(type, synthetic: true), "\(type.rawValue)")
        }
    }
}
