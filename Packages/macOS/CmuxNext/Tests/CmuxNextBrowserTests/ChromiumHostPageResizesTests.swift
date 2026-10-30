import CoreGraphics
@testable import CmuxNextBrowser
import Testing

/// Task p01-process-052: a hosted page's resize goes to the Chromium Host as one ordered op, only when
/// its size changed. The host's side is ChromiumHost/tests/host_resize_test.cpp.
@MainActor
@Suite struct ChromiumHostPageResizesTests {
    /// The wire: each resize, and what the next sends return.
    final class Wire: ChromiumHostPageResizeWire {
        struct Sent: Equatable {
            let view: UInt64
            let width: Int32
            let height: Int32
        }

        var sent: [Sent] = []
        /// What the next sends return; empty: sent.
        var outcomes: [Bool] = []

        func resize(view: UInt64, width: Int32, height: Int32) -> Bool {
            sent.append(Sent(view: view, width: width, height: height))
            return outcomes.isEmpty ? true : outcomes.removeFirst()
        }
    }

    let wire = Wire()

    func geometry(_ width: CGFloat, _ height: CGFloat) -> ChromiumHostGeometry {
        ChromiumHostGeometry(screenRect: CGRect(x: 10, y: 20, width: width, height: height), scale: 2)
    }

    @Test func onlyAChangedSizeIsSentAndAnUnsentOneIsTriedAgain() {
        let resizes = ChromiumHostPageResizes(wire: wire)
        resizes.resize(view: 1, geometry: geometry(300, 200))
        resizes.resize(view: 1, geometry: ChromiumHostGeometry(screenRect: CGRect(x: 90, y: 90, width: 300, height: 200), scale: 2))
        #expect(wire.sent.count == 1)  // a move is not a resize
        wire.outcomes = [false]
        resizes.resize(view: 1, geometry: geometry(320, 200))
        resizes.resize(view: 1, geometry: geometry(320, 200))
        #expect(wire.sent.map(\.width) == [300, 320, 320])
        resizes.resize(view: 0, geometry: geometry(10, 10))
        resizes.resize(view: 1, geometry: geometry(0, 10))
        #expect(wire.sent.count == 3)
        #expect(resizes.stats.resizes == 2)
    }

    /// A page window the host opened since (a new browser on the view's token) takes the size again.
    @Test func aResendSendsAnUnchangedSizeAgain() {
        let resizes = ChromiumHostPageResizes(wire: wire)
        resizes.resize(view: 1, geometry: geometry(300, 200))
        resizes.resize(view: 1, geometry: geometry(300, 200))
        #expect(wire.sent.count == 1)
        resizes.resize(view: 1, geometry: geometry(300, 200), resend: true)
        #expect(wire.sent == [Wire.Sent(view: 1, width: 300, height: 200), Wire.Sent(view: 1, width: 300, height: 200)])
        #expect(resizes.stats.resizes == 2)
    }
}
