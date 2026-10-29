import AppKit
@testable import CmuxNextDesign
import Testing

/// u15558 (2026-10-28): cmux NIGHTLY's Dock icon showed no unread badge while 7 tabs were unread.
/// With no window open, cmux runs without a Dock icon (`app.hideDockIconWithoutWindows`); when the
/// icon comes back, the Dock has dropped its badge while `NSDockTile.badgeLabel` still reads the old
/// label, so writing that label again shows nothing (measured on macOS 27). ``FakeDock`` behaves so.
@MainActor
struct DockBadgeTests {
    static func policies(_ values: NSApplication.ActivationPolicy...) -> AsyncStream<NSApplication.ActivationPolicy> {
        let (stream, continuation) = AsyncStream.makeStream(of: NSApplication.ActivationPolicy.self)
        for value in values { continuation.yield(value) }
        continuation.finish()
        return stream
    }

    @Test func theBadgeComesBackWithTheDockIcon() async {
        let dock = FakeDock()
        let badge = DockBadge(tile: dock)
        badge.show("7")
        #expect(dock.shown == "7")
        dock.removeIcon()
        await badge.follow(Self.policies(.accessory, .regular))
        #expect(dock.shown == "7", "the Dock icon came back without its badge")
    }

    @Test func aCountChangeWhileTheIconIsAwayShowsWhenItReturns() async {
        let dock = FakeDock()
        let badge = DockBadge(tile: dock)
        badge.show("2")
        dock.removeIcon()
        badge.show("3")
        await badge.follow(Self.policies(.accessory, .regular))
        #expect(dock.shown == "3")
    }

    @Test func anEqualCountWritesNothing() {
        let dock = FakeDock()
        let badge = DockBadge(tile: dock)
        badge.show("4")
        badge.show("4")
        #expect(dock.writes == 1)
    }

    /// `activationPolicies(of:)` observes its app with KVO, which keeps no reference to the app. When
    /// the stream let its app go, the app was freed while still observed ("NSRunningApplication ...
    /// is being deallocated while observers are still registered") and the observation's teardown
    /// then crashed on the freed app: the CloudBringBack cases died on signal 11 in
    /// -[NSRunningApplication removeObserver:forKeyPath:] under NotificationCenterService.start
    /// (cmux#26809, 2026-10-29). The stream keeps its app until it ends, then lets it go.
    @Test func thePolicyStreamKeepsItsAppUntilItEnds() async throws {
        weak var observed: NSRunningApplication?
        let stream = try autoreleasepool {
            let app = try #require(NSRunningApplication(processIdentifier: getpid()))
            observed = app
            return DockBadge.activationPolicies(of: app)
        }
        let aliveWhileFollowed = observed != nil
        #expect(aliveWhileFollowed, "the app was freed while the stream still observed it")
        // Its follower stops (as NotificationCenterService's task does when the service stops): the
        // stream ends, its observation ends, then it lets its app go.
        let follower = Task { for await _ in stream {} }
        follower.cancel()
        await follower.value
        let aliveAfterTheEnd = observed != nil
        #expect(!aliveAfterTheEnd, "the stream kept its app after it ended")
    }

    @Test func noBadgeStaysNoneWhenTheIconReturns() async {
        let dock = FakeDock()
        let badge = DockBadge(tile: dock)
        badge.show("1")
        badge.show(nil)
        dock.removeIcon()
        await badge.follow(Self.policies(.accessory, .regular))
        #expect(dock.shown == nil)
        #expect(dock.writes == 2, "a return with no badge wrote to the Dock")
    }
}

/// The Dock as measured: the tile keeps the label it was given and an equal write changes nothing;
/// removing the icon (accessory policy) drops what the Dock shows but not the tile's label.
@MainActor
private final class FakeDock: DockBadgeTile {
    private(set) var shown: String?
    private(set) var writes = 0
    private var stored: String?

    var badgeLabel: String? {
        get { stored }
        set {
            writes += 1
            guard newValue != stored else { return }
            stored = newValue
            shown = newValue
        }
    }

    func removeIcon() { shown = nil }
}
