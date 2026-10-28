import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import CmuxNextPages
import Foundation
import Testing

/// No New Tab page renderer before a New Tab page first shows (feature
/// `pageRendererAtFirstShow`): the launch arms no spare warm; the first New Tab page of the session
/// (``NewTabPreload/take(for:size:)``, which Cmd-T, Cmd-N and a restored page all call) arms it.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct NewTabSparePageLazinessTests {
    @Test func theLaunchMakesNoSpareUntilANewTabPageShows() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-lazy")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let tap = FakeInputTap()
            let slot = PagePreloadSlot(parkState: .renderedParked, deadlines: services.mainDeadlines)
            let pool = NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: tap,
                                     deadlines: MainDeadlineRig().deadlines, preloadOnMakeVisible: true)
            pool.webKit.markSlow() // the warm makes no web view: this test is about whether it is armed
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            pool.start()
            pool.retarget(window)
            pool.startWarming()
            #expect(tap.liveSubscriptions == 0, "the launch armed a spare page nobody opened")
            #expect(pool.spareView == nil)
            #expect(pool.take(for: window, size: nil) == nil, "no spare before the first New Tab page")
            #expect(tap.liveSubscriptions == 1, "the first New Tab page arms the next spare")
        }
    }
}
