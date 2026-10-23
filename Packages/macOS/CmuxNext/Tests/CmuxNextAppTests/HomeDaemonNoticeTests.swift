import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
@testable import CmuxNextHomeEngine
import Testing

/// Home says its daemon is too old only once the daemon answered that way. A
/// restore launch showed "Conversations need a newer cmux daemon." from 2012 to
/// 2339 ms while the Chief owner was still connecting (Leo 2026-10-21: "show
/// nothing, or the snapshot, until the daemon actually answers with an old version").
@MainActor
struct HomeDaemonNoticeTests {
    @Test func noTooOldNoticeWhileTheOwnerIsStillConnecting() async {
        let (services, view) = Self.home()
        await Self.settle()
        // Read outside `#expect`: it would reflect the view and the whole AppServices graph.
        let shownWhileConnecting = Self.showsUnavailable(view)
        #expect(!shownWhileConnecting, "the too-old notice shows while the owner is still connecting: \(Self.labels(view))")
        // A timeout or a closed socket says nothing about the owner's build.
        services.home.chief.noteFailure(.timedOut("identify"))
        await Self.settle()
        let refusedAfterTimeout = services.home.isRefused
        let shownAfterTimeout = Self.showsUnavailable(view)
        #expect(!refusedAfterTimeout, "a timeout counted as a refusal")
        #expect(!shownAfterTimeout, "the too-old notice shows after a timeout: \(Self.labels(view))")
    }

    @Test func theNoticeShowsOnceTheOwnerIsRefusedAsTooOld() async {
        let (services, view) = Self.home()
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapabilities.shared.localConversations]))
        let refused = services.home.isRefused
        #expect(refused, "a missing-capabilities refusal was not kept")
        let shownOnRefusal = await Self.wait { Self.showsUnavailable(view) }
        #expect(shownOnRefusal, "the too-old notice never showed after a refusal: \(Self.labels(view))")
        // A later retry that times out keeps the reason up.
        services.home.chief.noteFailure(.timedOut("identify"))
        await Self.settle()
        let shownAfterRetry = Self.showsUnavailable(view)
        #expect(shownAfterRetry, "a timeout after the refusal hid the notice: \(Self.labels(view))")
    }

    // MARK: Fixtures

    static func home() -> (AppServices, HomeHostView) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: "conv_local")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        return (services, view)
    }

    /// Lets the view's availability stream apply the newest state (test-only: nothing to wait on
    /// when the expected state is that nothing changes).
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// Waits up to five seconds for `done` (test-only), and says whether it came true.
    static func wait(until done: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    /// Each text field's text and whether it shows, for a failure's message.
    static func labels(_ view: NSView) -> String {
        view.layoutSubtreeIfNeeded()
        return descendants(of: view).compactMap { $0 as? NSTextField }
            .map { "\($0.stringValue.prefix(40))\($0.isHiddenOrHasHiddenAncestor ? " (hidden)" : "")" }
            .joined(separator: " | ")
    }

    static func showsUnavailable(_ view: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        return descendants(of: view).contains { field in
            (field as? NSTextField)?.stringValue == HomeStrings.unavailable && !field.isHiddenOrHasHiddenAncestor
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
