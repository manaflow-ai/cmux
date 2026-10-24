import AppKit
@testable import CmuxNextBrowser
import Testing

/// A woken (hibernated) Chromium tab shows its last picture over the page until the page paints
/// (PL-memory, 2026-10-24: "waking a hibernated tab must look instant"). Before, the snapshot went
/// away as soon as the restored page was created, and the theme color showed for 41-157 ms p50
/// until Chromium's first frame. The stand-in lives in the cmux window's layers, so only a layer
/// hosted page can have one; a page in its own child window keeps today's gap.
@MainActor
@Suite struct CEFWakeStandInTests {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let owner = NSObject()
    let other = NSObject()

    func makeHosting(enabled: Bool = true, clock: any Clock<Duration> = NeverClock()) -> CEFLayerHosting {
        let hosting = CEFLayerHosting(isEnabled: { enabled }, schedule: { $0() },
                                      makePage: { CEFHostedPageView(frame: $0, makeLayerHost: { _ in CALayer() }) },
                                      standInClock: clock)
        hosting.view = view
        return hosting
    }

    static let picture: CGImage = {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context, let image = context.makeImage() else { preconditionFailure("a 4x3 bitmap context") }
        return image
    }()

    @Test func aStandInCoversThePageUntilItsTabPaints() throws {
        let hosting = makeHosting()
        #expect(hosting.showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: true))
        let standIn = try #require(view.subviews.last as? CEFWakeStandInView)
        #expect(standIn.layer?.contents != nil)
        #expect(standIn.frame == view.bounds)
        // Another tab's paint does not end it.
        hosting.documentPainted(owner: ObjectIdentifier(other))
        #expect(hosting.hasStandIn)
        hosting.documentPainted(owner: ObjectIdentifier(owner))
        #expect(!hosting.hasStandIn)
        #expect(!view.subviews.contains { $0 is CEFWakeStandInView })
    }

    @Test func anotherTabShownInThePaneEndsTheStandIn() {
        let hosting = makeHosting()
        _ = hosting.showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: true)
        hosting.tabShown(owner: ObjectIdentifier(owner))
        #expect(hosting.hasStandIn)
        hosting.tabShown(owner: ObjectIdentifier(other))
        #expect(!hosting.hasStandIn)
    }

    @Test func aPageThatNeverPaintsLosesItsStandInAtTheCap() async throws {
        let hosting = makeHosting(clock: ImmediateStandInClock())
        _ = hosting.showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: true)
        var turns = 0
        while hosting.hasStandIn, turns < 500 { turns += 1; try await Task.sleep(for: .milliseconds(2)) } // test harness: the cap fires on a later task turn
        #expect(!hosting.hasStandIn)
    }

    @Test func noStandInWithoutLayerHosting() {
        #expect(!makeHosting(enabled: false).showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: true))
        #expect(!makeHosting().showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: false))
        #expect(view.subviews.isEmpty)
    }

    @Test func stoppingTheHostingEndsTheStandIn() {
        let hosting = makeHosting()
        _ = hosting.showStandIn(Self.picture, owner: ObjectIdentifier(owner), cap: .milliseconds(500), hostingAvailable: true)
        hosting.stop()
        #expect(!hosting.hasStandIn)
    }
}

/// A clock whose sleeps never end (until cancelled): the cap never fires.
nonisolated struct NeverClock: Clock {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until _: Instant, tolerance _: Duration?) async throws {
        try await Task.sleep(for: .seconds(3_600)) // test clock: a deadline that never comes during a test; cancelled with it
    }
}

/// A clock whose sleeps end at once: the cap fires on the next task turn.
nonisolated struct ImmediateStandInClock: Clock {
    nonisolated struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    var now: Instant { Instant() }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until _: Instant, tolerance _: Duration?) async throws {}
}
