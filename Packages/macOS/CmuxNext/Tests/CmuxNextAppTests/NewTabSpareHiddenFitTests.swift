import AppKit
import CmuxNextActions
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// RESIZE MAIN BUDGET (cmux-ad m16 item 5; coordinator's rule: hidden work is model only during a motion, then one
/// layout at the final size). The parked New Tab spare followed its target pane's size 120 ms after each pane resize
/// (`fitSettle`); a key resize's spring outlasts that, so the fit (a hidden web page laid out at the new size,
/// `PageOffscreenParking.fit`) ran in a motion frame: 3.6 ms of main thread in the p99 frames of the 4-terminal key resize
/// (Time Profiler of job ed08902c). A spare that keeps its old size instead shows no cover on the next Cmd-T (review of
/// #36266). Now the spare takes its pane's size in one background fit once the window's layout is still.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct NewTabSpareHiddenFitTests {
    /// Two key resizes in a split, the second right after the first landed: the parked spare is never laid out while
    /// the layout moves, and is at its pane's final size once the second lands, before any Cmd-T.
    @Test func aKeyResizeFitsNoParkedSpareInItsFramesAndTheSpareIsAtThePanesSizeAfterItLands() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-motion-fit")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, first) = try await NewTabOpenFramesTests.focusedPane(services)
            let controller = try #require(services.windows.active)
            let folder = try NewTabRapidPairTests.folder()
            var rig: NewTabRapidPairTests.Rig?
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            #expect(services.registry.perform("splitRight", invocation: ActionInvocation(origin: .user)))
            try await PasswordManagerRouteTests.until({ controller.focusedPane != nil && controller.focusedPane !== first },
                                                      report: { "the split never took the focus" })
            let pane = try #require(controller.focusedPane)
            let layout = try #require(controller.content?.layoutView)
            try await PasswordManagerRouteTests.until({ !layout.isInLayoutMotion }, report: { "the split never landed" })
            rig = try await NewTabRapidPairTests.filledPool(services, window: window, folder: folder)
            let spare = try #require(services.newTabSpares.spare?.view)
            try await PasswordManagerRouteTests.until({ spare.frame.size == NewTabSparePool.newTabContentSize(in: pane) },
                                                      report: { "the spare \(spare.frame.size) never took its pane's size before the presses" })

            // Every frame of the two springs: the spare's size, while the layout moves.
            var sizesInMotion: [CGSize] = []
            var sawMotion = false
            let start = spare.frame.size
            let watch = layout.observeOverlaySync {
                guard layout.isInLayoutMotion else { return }
                sawMotion = true
                if spare.frame.size != start, sizesInMotion.last != spare.frame.size { sizesInMotion.append(spare.frame.size) }
            }
            defer { watch.cancel() }
            for action in ["resizePaneLeft", "resizePaneRight"] {
                #expect(services.registry.perform(action, invocation: ActionInvocation(origin: .user)), "\(action) was refused")
                try await PasswordManagerRouteTests.until({ layout.isInLayoutMotion }, within: .seconds(2), report: { "\(action) did not spring" })
                try await PasswordManagerRouteTests.until({ !layout.isInLayoutMotion }, within: .seconds(3), report: { "\(action) never landed" })
            }
            #expect(sawMotion, "no frame of the springs was seen")
            #expect(sizesInMotion.isEmpty, "the hidden spare was laid out while the layout moved: \(start) -> \(sizesInMotion)")
            let final = NewTabSparePool.newTabContentSize(in: pane)
            try await PasswordManagerRouteTests.until({ spare.frame.size == final }, within: .seconds(2),
                                                      report: { "after the landing the spare is \(spare.frame.size), its pane's content is \(final)" })
        }
    }

    /// A window resize (no spring): the spare takes its pane's new size before the next Cmd-T, which shows it at that size
    /// with no refit in its turn.
    @Test func afterAWindowResizeTheSpareIsAtThePanesSizeAndCmdTTakesItWithNoRefit() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-spare-resize-fit")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, pane) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            var rig: NewTabRapidPairTests.Rig?
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            rig = try await NewTabRapidPairTests.filledPool(services, window: window, folder: folder)
            let pool = services.newTabSpares
            let spare = try #require(pool.spare?.view)
            let content = try #require(window.contentView)
            window.setContentSize(NSSize(width: content.bounds.width - 240, height: content.bounds.height - 120))
            content.layoutSubtreeIfNeeded()
            let size = NewTabSparePool.newTabContentSize(in: pane)
            try #require(size != spare.frame.size, "the pane kept the spare's size (\(size)): nothing to follow")
            try await PasswordManagerRouteTests.until({ spare.frame.size == size }, within: .seconds(2),
                                                      report: { "the spare is \(spare.frame.size), its pane's content is \(size)" })
            let openings = pool.openings.count
            NewTabPage.open(in: pane, seed: nil)
            let opened = try #require(pool.openings.dropFirst(openings).first, "Cmd-T recorded no opening")
            #expect(opened.spare, "Cmd-T loaded cold instead of taking the parked spare")
            #expect(!opened.refit, "Cmd-T found the spare at another size than its pane's")
        }
    }
}
