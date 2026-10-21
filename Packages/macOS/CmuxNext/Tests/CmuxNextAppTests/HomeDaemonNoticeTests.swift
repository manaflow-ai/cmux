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
        #expect(!Self.showsUnavailable(view))
        // A timeout or a closed socket says nothing about the owner's build.
        services.home.chief.noteFailure(.timedOut("identify"))
        await Self.settle()
        #expect(!Self.showsUnavailable(view))
    }

    @Test func theNoticeShowsOnceTheOwnerIsRefusedAsTooOld() async {
        let (services, view) = Self.home()
        services.home.chief.noteFailure(.missingCapabilities([DaemonCapabilities.shared.localConversations]))
        await Self.settle()
        #expect(Self.showsUnavailable(view))
        // A later retry that times out keeps the reason up.
        services.home.chief.noteFailure(.timedOut("identify"))
        await Self.settle()
        #expect(Self.showsUnavailable(view))
    }

    // MARK: Fixtures

    static func home() -> (AppServices, HomeHostView) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let view = HomeHostView(services: services, conversation: "conv_local")
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        return (services, view)
    }

    /// Lets the view's availability stream apply the newest state.
    static func settle() async {
        for _ in 0..<10 { await Task.yield() }
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
