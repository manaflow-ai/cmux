import CoreGraphics
import Testing
@testable import CmuxMobileTerminal

/// design/terminal R3-1: a pull-down above the keyboard scrolls the history.
@Suite struct KeyboardDragPinTests {
    @Test func aDragAboveTheKeyboardScrolls() {
        var pin = KeyboardDragPin()
        pin.began(following: true, keyboardUp: true, isTUI: false)
        pin.moved(fingerY: 150, keyboardTop: 560)
        pin.moved(fingerY: 400, keyboardTop: 560)
        #expect(!pin.pinning)
    }

    @Test func reachingTheKeyboardPinsTheFollowingReader() {
        var pin = KeyboardDragPin()
        pin.began(following: true, keyboardUp: true, isTUI: false)
        pin.moved(fingerY: 300, keyboardTop: 560)
        pin.moved(fingerY: 562, keyboardTop: 560)
        #expect(pin.pinning)
        pin.ended()
        #expect(!pin.pinning)
    }

    @Test func aDragThatScrolledThenReachedTheKeyboardEndsOnThePrompt() {
        var pin = KeyboardDragPin()
        pin.began(following: true, keyboardUp: true, isTUI: false)
        pin.moved(fingerY: 300, keyboardTop: 560)
        #expect(!pin.pinning)
        pin.moved(fingerY: 570, keyboardTop: 560)
        #expect(pin.pinning)
    }

    @Test func aReaderAlreadyScrolledUpIsNeverPinned() {
        var pin = KeyboardDragPin()
        pin.began(following: false, keyboardUp: true, isTUI: false)
        pin.moved(fingerY: 700, keyboardTop: 560)
        #expect(!pin.pinning)
    }

    @Test func noKeyboardOrATUINeverPins() {
        var pin = KeyboardDragPin()
        pin.began(following: true, keyboardUp: false, isTUI: false)
        pin.moved(fingerY: 800, keyboardTop: 874)
        #expect(!pin.pinning)
        pin.began(following: true, keyboardUp: true, isTUI: true)
        pin.moved(fingerY: 800, keyboardTop: 560)
        #expect(!pin.pinning)
    }
}
