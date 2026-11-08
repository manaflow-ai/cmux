import CoreGraphics
import Testing
@testable import CmuxMobileBrowserStream

/// Mac click-count semantics for phone taps: a double tap must reach the Mac
/// as a double click (word selection), never as a local zoom gesture.
struct BrowserStreamTapClickCounterTests {
    @Test func quickSecondTapBecomesDoubleClick() {
        var counter = BrowserStreamTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 100, y: 100), time: 10.0) == 1)
        #expect(counter.register(at: CGPoint(x: 104, y: 98), time: 10.3) == 2)
    }

    @Test func thirdTapBecomesTripleClick() {
        var counter = BrowserStreamTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 50, y: 50), time: 1.0) == 1)
        #expect(counter.register(at: CGPoint(x: 50, y: 50), time: 1.3) == 2)
        #expect(counter.register(at: CGPoint(x: 50, y: 50), time: 1.6) == 3)
    }

    @Test func slowSecondTapRestartsAtSingleClick() {
        var counter = BrowserStreamTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 100, y: 100), time: 10.0) == 1)
        #expect(counter.register(at: CGPoint(x: 100, y: 100), time: 10.6) == 1)
    }

    @Test func distantSecondTapRestartsAtSingleClick() {
        var counter = BrowserStreamTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 100, y: 100), time: 10.0) == 1)
        #expect(counter.register(at: CGPoint(x: 180, y: 100), time: 10.2) == 1)
    }

    @Test func chainRestartsAfterBreak() {
        var counter = BrowserStreamTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 1.0) == 1)
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 1.2) == 2)
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 5.0) == 1)
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 5.2) == 2)
    }
}
