import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5, coordinator's rule: hidden work is model only). The parked New Tab spare
/// followed its target pane's size: each pane resize scheduled a fit 120 ms later (`fitSettle`), and a key resize's
/// spring runs longer than that, so the fit (a hidden web page laid out at the new size, `PageOffscreenParking.fit`)
/// landed in a motion frame: 3.6 ms of main thread in the p99 frames of the 4-terminal key resize (Time Profiler of
/// job ed08902c; keys p99 11.5 ms against p95 6.3). A hidden page gets no layout; the New Tab that takes it lays it out
/// once, at its pane's size.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabSpareHiddenFitTests {
    @Test func aPaneResizeLaysOutNoParkedSpareAndTheNewTabTakesItAtItsSize() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-hidden-fit")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            var rig: NewTabRapidPairTests.Rig?
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            rig = try await NewTabRapidPairTests.filledPool(services, window: window, folder: folder)
            let pool = services.newTabSpares
            let spare = try #require(pool.spare?.view)
            let parkedSize = spare.frame.size

            // The pane shrinks (the window does; a key resize or a divider drag changes it the same way).
            let content = try #require(window.contentView)
            window.setContentSize(NSSize(width: content.bounds.width - 240, height: content.bounds.height - 120))
            content.layoutSubtreeIfNeeded()
            let paneSize = NewTabSparePool.newTabContentSize(in: pane)
            try #require(paneSize != parkedSize, "the pane kept its size (\(paneSize)): nothing to follow")
            pool.paneLayoutDidChange(in: window)
            // Past the settle a follow would have waited for (`fitSettle`, 120 ms).
            try await Task.sleep(for: .milliseconds(600))
            #expect(spare.frame.size == parkedSize,
                    "the hidden spare was laid out at the pane's new size (\(parkedSize) -> \(spare.frame.size)) before any New Tab showed it")

            // Cmd-T takes it: it shows at its pane's size, laid out once there.
            let openings = pool.openings.count
            NewTabPage.open(in: pane, seed: nil)
            let opened = try #require(pool.openings.dropFirst(openings).first, "Cmd-T recorded no opening")
            #expect(opened.spare, "Cmd-T loaded cold instead of taking the parked spare")
            pane.view.layoutSubtreeIfNeeded()
            #expect(spare.frame.size == NewTabSparePool.newTabContentSize(in: pane),
                    "the taken spare shows at \(spare.frame.size), its pane's content is \(NewTabSparePool.newTabContentSize(in: pane))")
        }
    }
}
