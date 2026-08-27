import CMUXMobileCore
import CoreGraphics
import Testing
@testable import CmuxMobileBrowserStream

@Suite struct BrowserStreamScrollBatcherTests {
    @Test func coalescesMovementWithoutOverwritingGestureBoundaries() throws {
        var batcher = BrowserStreamScrollBatcher()
        batcher.consume(.trackingBegan)
        batcher.consume(.trackingChanged, delta: CGPoint(x: 2, y: 3))
        batcher.consume(.trackingChanged, delta: CGPoint(x: 5, y: 7))
        batcher.consume(.trackingEnded(willDecelerate: false))

        let beganValue = batcher.next()
        let began = try #require(beganValue)
        #expect(began.phase == .began)
        #expect(began.delta == CGPoint(x: 7, y: 10))
        let endedValue = batcher.next()
        let ended = try #require(endedValue)
        #expect(ended.phase == .ended)
        #expect(ended.delta == .zero)
        #expect(batcher.next() == nil)
    }

    @Test func preservesMomentumBeginAndEndAroundCoalescedDeltas() throws {
        var batcher = BrowserStreamScrollBatcher()
        batcher.consume(.trackingBegan)
        batcher.consume(.trackingChanged, delta: CGPoint(x: 0, y: 4))
        batcher.consume(.trackingEnded(willDecelerate: true))
        batcher.consume(.momentumBegan)
        batcher.consume(.momentumChanged, delta: CGPoint(x: 0, y: 9))
        batcher.consume(.momentumEnded)

        let beganValue = batcher.next()
        #expect(try #require(beganValue).phase == .began)
        let endedValue = batcher.next()
        #expect(try #require(endedValue).phase == .ended)
        let momentumValue = batcher.next()
        let momentum = try #require(momentumValue)
        #expect(momentum.phase == .momentumBegan)
        #expect(momentum.delta == CGPoint(x: 0, y: 9))
        let momentumEndedValue = batcher.next()
        #expect(try #require(momentumEndedValue).phase == .momentumEnded)
    }
}
