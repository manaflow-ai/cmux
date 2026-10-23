import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDesign
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
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapability.localConversations.rawValue]))
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

    @Test func aSuccessfulHandshakeAfterARefusalTakesTheNoticeDown() async {
        let (services, view) = Self.home()
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapability.localConversations.rawValue]))
        let shownOnRefusal = await Self.wait { Self.showsUnavailable(view) }
        #expect(shownOnRefusal, "the too-old notice never showed after a refusal: \(Self.labels(view))")
        // A newer owner answers; it gets ready (restart check, prepare) before it attaches.
        services.home.chief.noteHandshakeAccepted()
        let refusedAfterAnswer = services.home.isRefused
        #expect(!refusedAfterAnswer, "the old refusal outlived a successful handshake")
        let hiddenAfterAnswer = await Self.wait { !Self.showsUnavailable(view) }
        #expect(hiddenAfterAnswer, "the too-old notice stayed up after the owner answered: \(Self.labels(view))")
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

    /// Each text and whether it shows, for a failure's message.
    static func labels(_ view: NSView) -> String {
        view.layoutSubtreeIfNeeded()
        return texts(in: view)
            .map { text, field in "\(text.prefix(40))\(field.isHiddenOrHasHiddenAncestor ? " (hidden)" : "")" }
            .joined(separator: " | ")
    }

    static func showsUnavailable(_ view: NSView) -> Bool {
        view.layoutSubtreeIfNeeded()
        return texts(in: view).contains { text, field in text == HomeStrings.unavailable && !field.isHiddenOrHasHiddenAncestor }
    }

    /// Each text the view tree draws: Home's notice is a `ChromeLabel` (an NSView), other text fields are `NSTextField`s.
    static func texts(in view: NSView) -> [(String, NSView)] {
        descendants(of: view).compactMap { field in
            if let label = field as? ChromeLabel { return (label.stringValue, field) }
            if let label = field as? NSTextField { return (label.stringValue, field) }
            return nil
        }
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
