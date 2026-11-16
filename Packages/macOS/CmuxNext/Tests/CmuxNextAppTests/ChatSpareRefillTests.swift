import AppKit
@testable import CmuxNextAgentPane
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// A chat that takes the pool's connected page leaves the pool empty. The next page came only once the person's
/// input was quiet for the pool's idle wait, and each key, click or scroll pushed that wait back: a person who read
/// a chat, scrolled it and clicked the next one found no page, so that chat built a page of its own and ran every
/// wait of a cold open. The next page now follows the chat's first paint, whatever the input does (decision
/// 2026-11-16).
///
/// Limit: a second chat selected before the first one painted, or before the next page loaded and connected, still
/// finds no page. The pool keeps one page.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"),
                  .closesItsWindows)
struct ChatSpareRefillTests {
    @Test func aSecondChatFindsAConnectedPageOnceTheFirstPaintedWhileInputNeverGoesQuiet() async throws {
        try await PasswordManagerRouteTests.withApp { services, _ in
            services.agentTabs.localHost = AgentSessionRef.host(installID: "cn-chat-spare-refill")
            try #require(services.agentTabs.canHostChat, "this build has no New Tab page")
            let (window, _) = try await NewTabOpenFramesTests.focusedPane(services)
            let folder = try NewTabRapidPairTests.folder()
            let rig = NewTabRapidPairTests.Rig()
            defer { NewTabRapidPairTests.cleanUp(services, rig, folder) }
            let html = folder.appending(path: "index.html")
            try Data("<html><body>New Tab spare fixture</body></html>".utf8).write(to: html)
            let pool = services.newTabSpares
            pool.dropAll()
            // Inert pages stand in for the real ones: each counts as loaded, drawn and connected to acpmux.
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
            // From here on the person's input never goes quiet (they scroll, type and click on): the pool's own
            // quiet-input warm never comes.
            pool.idleInput = .seconds(3600)

            // The first chat takes the connected page, as a sidebar click does, and the page switches to the chat.
            let first = try #require(services.agentTabs.takeConnectedSpare?(),
                                     "the first chat found no connected page (Low Power Mode or a hot Mac refuses it)")
            #expect(first === rig.made.first)
            try #require(first.model.adoptSpareSession("s-first"), "the page refused the chat: \(first.model.spareRefusal)")
            #expect(pool.spares.isEmpty, "the pool keeps one page: the chat took it")
            // The page drew the chat.
            first.model.markPainted()

            try await PasswordManagerRouteTests.until({ rig.made.count == 2 && pool.spare != nil }, within: .seconds(5), report: {
                "no page followed the first chat's paint; \(NewTabRapidPairTests.poolState(services, rig))"
            })
            let second = try #require(services.agentTabs.takeConnectedSpare?(), "the second chat found no connected page")
            #expect(second === rig.made.last && second !== first, "the second chat did not get the page made after the first chat's paint")
        }
    }
}
