#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import Testing

/// Host mode's input route (p01-process-042 on 041's ring and 092's seqs): a hosted page view's
/// frames go into the ring for the browser its pane shows, stamped with the remote shim's input
/// and control seqs; the host's acks reach that page's pacer; no host writes nothing and stalls
/// nothing; the host's end takes every page off the route.
@MainActor
@Suite struct ChromiumHostInputRouteTests {
    /// A route over a fresh ring whose order seam hands out input seqs from 41, after control seq 7.
    final class Rig {
        let fixture: ChromiumHostInputRingTests.Fixture
        let route: ChromiumHostInputRoute
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                                        makeLayerHost: { _ in CALayer() })
        var nextSeq: UInt32 = 41
        var attached = true
        var browser: Int32? = 9

        init() throws {
            fixture = try ChromiumHostInputRingTests.Fixture()
            var order: ChromiumHostInputRoute.Order = { nil }
            route = ChromiumHostInputRoute(ring: fixture.ring, order: { order() })
            order = { [unowned self] in
                guard self.attached else { return nil }
                defer { self.nextSeq += 1 }
                return (self.nextSeq, 7)
            }
            route.attach(page) { [unowned self] in self.browser }
        }

        /// The `t1` of the frame at ring position `index`: the browser low, the control seq high.
        func t1(at index: UInt64) -> UInt64 {
            let slot = ChromiumHostInputRing.framesOffset + Int(index % ChromiumHostInputRing.capacity) * ChromiumHostInputRing.frameSize
            return UInt64(littleEndian: fixture.base.loadUnaligned(fromByteOffset: slot + 48, as: UInt64.self))
        }

        var written: UInt64 { fixture.word(ChromiumHostInputRing.tailOffset).load(ordering: .acquiring) }
    }

    static func moved(_ x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: x, y: 10), modifierFlags: [], timestamp: 1,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    @Test func aPageOnTheRouteWritesStampedFramesForItsShownBrowser() throws {
        let rig = try Rig()
        #expect(rig.page.pacesInput && rig.page.hostReportsUnhandledKeys)
        rig.page.mouseMoved(with: try Self.moved(3))
        #expect(rig.written == 1)
        #expect(rig.fixture.kind(at: 0) == ChromiumHostFrame.Kind.mouse.rawValue)
        #expect(rig.fixture.seq(at: 0) == 41)
        #expect(rig.t1(at: 0) == (UInt64(7) << 32 | 9))
        #expect(rig.route.stats.written == 1)
    }

    @Test func theHostsAckOfTheMoveSendsTheLatestWaitingOne() throws {
        let rig = try Rig()
        for x in 1...5 { rig.page.mouseMoved(with: try Self.moved(CGFloat(x))) }
        #expect(rig.written == 1)
        rig.route.acked(browser: 9, kind: Int32(ChromiumHostFrame.Kind.mouse.rawValue), seq: 41)
        #expect(rig.written == 2)
        #expect(rig.fixture.x(at: 1) == 5)
        #expect(rig.fixture.seq(at: 1) == 42)
        rig.route.acked(browser: 9, kind: Int32(ChromiumHostFrame.Kind.mouse.rawValue), seq: 42)
        #expect(rig.page.inputPacer?.movesInFlight == 0)
        #expect(rig.page.inputPacer?.stats.maxMovesInFlight == 1)
    }

    @Test func withNoHostAttachedNothingIsWrittenAndNothingWaits() throws {
        let rig = try Rig()
        rig.attached = false
        for x in 1...3 { rig.page.mouseMoved(with: try Self.moved(CGFloat(x))) }
        #expect(rig.written == 0)
        #expect(rig.route.stats.unwritten == 3)
        #expect(rig.page.inputPacer?.movesInFlight == 0)  // no ack will come: nothing stays in flight
    }

    @Test func focusNeverGoesOnTheRing() throws {
        let rig = try Rig()
        #expect(rig.page.sendInput(ChromiumHostFrame(.focus, v: [1])) == nil)
        #expect(rig.written == 0)
    }

    @Test func anAckForABrowserNoPageSentToIsCounted() throws {
        let rig = try Rig()
        rig.route.acked(browser: 99, kind: Int32(ChromiumHostFrame.Kind.wheel.rawValue), seq: 1)
        #expect(rig.route.stats.strayAcks == 1)
    }

    @Test func theHostsEndTakesEveryPageOffTheRoute() throws {
        let rig = try Rig()
        rig.route.hostEnded()
        #expect(rig.page.sink == nil)
        #expect(!rig.page.pacesInput && !rig.page.hostReportsUnhandledKeys)
        rig.page.mouseMoved(with: try Self.moved(1))
        #expect(rig.written == 0)
    }
}
#endif
