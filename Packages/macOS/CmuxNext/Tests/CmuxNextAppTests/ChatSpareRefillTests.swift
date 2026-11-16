import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import CmuxNextWakeups
import Foundation
import Testing

/// A chat that takes the pool's connected page leaves the pool empty. The next page came only once the person's
/// input was quiet for the pool's idle wait, and each key, click or scroll pushed that wait back: a person who read
/// a chat, scrolled it and clicked the next one found no page, so that chat built a page of its own and ran every
/// wait of a cold open. The next page now follows the chat's first paint, whatever the input does (decision
/// 2026-11-16).
///
/// Limit: a second chat selected before the first one painted, or before the next page loaded and connected, still
/// finds no page. The pool keeps one page. That second chat builds its own page, and the pool's next page is not
/// made while that page has not drawn.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct ChatSpareRefillTests {
    /// A chat page on screen that has not drawn (a second chat's own cold page), as the pool's wait for shown chats
    /// sees it.
    @MainActor final class ColdChat {
        var loads = false
        /// What the page runs once it drew.
        var drew: (() -> Void)?
    }

    /// The app with one inert page parked: each inert page counts as loaded, drawn and connected to acpmux. From
    /// there on the person's input never goes quiet (they scroll, type and click on), so the pool's own quiet-input
    /// warm never comes.
    static func withPool(_ id: String, _ body: (AppServices, NewTabSparePool, NewTabRapidPairTests.Rig) async throws -> Void) async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: id)
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, _) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            let rig = NewTabRapidPairTests.Rig()
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            pool.dropAll()
            pool.makeSpare = { page in
                let model = AgentPaneModel(host: services.agentTabs.host, newTab: page)
                guard let view = AgentPaneView(model: model, source: .bundled(html)) else { return nil }
                model.hasHandshake = true
                model.markPainted()
                model.clientReady = true
                rig.made.append(view)
                return view
            }
            pool.retarget(window)
            pool.prewarm()
            pool.start()
            try await PasswordManagerRouteTests.until({ rig.made.count == 1 && pool.spare != nil }, within: .seconds(5),
                                                      report: { "no page at the start; \(NewTabRapidPairTests.poolState(services, rig))" })
            pool.idleInput = .seconds(3600)
            try await body(services, pool, rig)
        }
    }

    /// This run-loop pass committed its frame.
    static func frameCommit() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in AfterFrameCommit().run { done.resume() } }
    }

    @Test func aSecondChatFindsAConnectedPageOnceTheFirstPaintedWhileInputNeverGoesQuiet() async throws {
        try await Self.withPool("cn-chat-spare-refill") { services, pool, rig in
            // The first chat takes the connected page, as a sidebar click does, and the page switches to the chat.
            let first = try #require(services.agentTabs.takeConnectedSpare?(),
                                     "the first chat found no connected page (Low Power Mode or a hot Mac refuses it)")
            #expect(first === rig.made.first)
            try #require(first.model.adoptSpareSession("s-first"), "the page refused the chat: \(first.model.spareRefusal)")
            #expect(pool.spares.isEmpty, "the pool keeps one page: the chat took it")
            // The refill asks the page for its paint after this turn's commit (two commits: the test's own observer
            // can run before the refill's in the first one). Until the page drew the chat, the refill only waits.
            await Self.frameCommit()
            await Self.frameCommit()
            #expect(first.model.paintWaiters.count == 1, "the refill does not wait for the chat's paint: \(first.model.paintWaiters.count) wait for it")
            #expect(rig.made.count == 1, "a page was made before the chat's paint")
            // The page drew the chat.
            first.model.markPainted()

            try await PasswordManagerRouteTests.until({ rig.made.count == 2 && pool.spare != nil }, within: .seconds(5), report: {
                "no page followed the first chat's paint; \(NewTabRapidPairTests.poolState(services, rig))"
            })
            // The page a second chat gets. It stays in the pool: a take here started one more refill, whose make
            // came after the test's end.
            let second = try #require(pool.spare?.view)
            #expect(second === rig.made.last && second !== first, "the pool's page is not the one made after the first chat's paint")
            #expect(second.model.servesExistingChat, "a second chat cannot take the page made after the first chat's paint")
        }
    }

    /// A second chat that found no page builds its own. While that page has not drawn, the pool's next page is not
    /// made: its main-thread tasks would land in that chat's open. It follows that chat's paint.
    @Test func aChatThatStillLoadsHoldsTheNextPage() async throws {
        try await Self.withPool("cn-chat-spare-refill-hold") { services, pool, rig in
            let cold = ColdChat()
            pool.shownChats.standIn = { cold.loads ? [{ cold.drew = $0 }] : [] }
            defer { pool.shownChats.standIn = nil }
            let first = try #require(services.agentTabs.takeConnectedSpare?(),
                                     "the first chat found no connected page (Low Power Mode or a hot Mac refuses it)")
            try #require(first.model.adoptSpareSession("s-first"), "the page refused the chat: \(first.model.spareRefusal)")
            // The second chat's own page is on screen and loads; then the first chat's page drew.
            cold.loads = true
            first.model.markPainted()

            try await PasswordManagerRouteTests.until({ pool.refills.counts.heldForOpen > 0 || rig.made.count > 1 }, within: .seconds(5), report: {
                "the first chat's refill never came due; \(pool.refills.counts); \(NewTabRapidPairTests.poolState(services, rig))"
            })
            #expect(rig.made.count == 1, "a page was made while a chat on screen had not drawn")
            #expect(pool.refills.counts.heldForOpen == 1, "\(pool.refills.counts)")

            // The second chat drew.
            cold.loads = false
            let paint = try #require(cold.drew, "the held make did not ask the chat's page for its paint")
            paint()
            try await PasswordManagerRouteTests.until({ rig.made.count == 2 && pool.spare != nil }, within: .seconds(5), report: {
                "no page followed the second chat's paint; \(pool.refills.counts); \(NewTabRapidPairTests.poolState(services, rig))"
            })
            #expect(pool.spare?.view === rig.made.last)
        }
    }
}
