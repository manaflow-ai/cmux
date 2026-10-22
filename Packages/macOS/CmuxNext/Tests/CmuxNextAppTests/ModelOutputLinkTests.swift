import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextDaemonService
import Foundation
import Testing

/// Media safety R8 (leo-workspace#874): a cmux link clicked in model output (an agent's reply, the
/// Chief's transcript) only reveals what is already open. A `tab/` link to a closed tab leaves it
/// closed, and a `session/` link with no tab creates none; both answer "not open" with the link.
/// The same links from the person's own surfaces (Open Link…, a pasted link, the CLI) still
/// reopen the tab and create the chat tab, as before. Each test checks the effect, not the route.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ModelOutputLinkTests {
    /// What one click did: the refusal it showed and the work it started.
    private struct Click {
        var opened: Bool
        var refusal: String?
        var work: [ActionWork]
    }

    /// A click on `link` the way the agent pane and Home hand it to the app (``CmuxAppLinks/open(_:services:origin:)``).
    private static func click(_ link: String, _ origin: DeepLink.Origin, _ services: AppServices) throws -> Click {
        let url = try #require(URL(string: link))
        var opened = false
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { opened = CmuxAppLinks.open(url, services: services, origin: origin) }
        }
        return Click(opened: opened, refusal: refusal, work: work)
    }

    private static func allTabs(_ store: DaemonStore) -> [String] {
        store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id)
    }

    /// A browser tab in the first pane, unselected, and its `tab_` resource id.
    private static func browserTab(_ services: AppServices, _ connection: DaemonConnection) async throws -> (SurfaceID, String) {
        let store = services.daemon.store
        let pane = try #require(store.workspaces.first?.screens.first?.panes.first)
        let url = "https://r8-\(UUID().uuidString.prefix(6).lowercased()).example/"
        let made = try await connection.newFrontendBrowserTab(url: url, engine: .webkit, in: pane.handle, activate: false)
        try await PinnedPageTests.until({ store.tab(surface: made.surface)?.resourceID != nil })
        return (made.surface, try #require(store.tab(surface: made.surface)?.resourceID?.rawValue))
    }

    @Test func aModelOutputTabLinkLeavesAClosedTabClosedAndThePersonsReopensIt() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let store = services.daemon.store
            let (surface, id) = try await Self.browserTab(services, connection)
            try await connection.closeTab(surface)
            try await PinnedPageTests.until({ services.locateTab(id) == nil })
            let link = try #require(services.linkText(DeepLink(.tab(id))))
            let before = Self.allTabs(store)

            let model = try Self.click(link, .modelOutput, services)
            #expect(model.opened, "the app did not take the link")
            #expect(model.refusal == RefusalStrings.linkTargetNotOpen(link))
            #expect(model.work.isEmpty, "a model-output link started work: \(model.work.count)")
            // The store hears every reopen as an event; give one a moment to arrive before checking.
            try await Task.sleep(for: .milliseconds(500))
            #expect(services.locateTab(id) == nil, "a model-output link reopened the closed tab")
            #expect(Self.allTabs(store) == before, "a model-output link changed the tab store")

            let person = try Self.click(link, .person, services)
            #expect(person.refusal == nil, "refused: \(person.refusal ?? "")")
            for task in person.work { if let failure = await task.value { Issue.record("the reopen failed: \(failure.message)") } }
            try await PinnedPageTests.until({ services.locateTab(id) != nil }, report: { "the person's link did not reopen the tab" })
        }
    }

    @Test func aModelOutputTabLinkStillRevealsAnOpenTab() async throws {
        try await PinnedPageTests.withApp { services, connection in
            let (surface, id) = try await Self.browserTab(services, connection)
            let (tab, pane) = try #require(services.locateTab(id))
            let controller = try #require(services.paneController(for: pane))
            try #require(controller.stripModel.selectedID?.rawValue != tab.id, "the new tab was selected before the link")
            let link = try #require(services.linkText(DeepLink(.tab(id))))

            let model = try Self.click(link, .modelOutput, services)
            #expect(model.refusal == nil, "refused: \(model.refusal ?? "")")
            try await PinnedPageTests.until({ controller.stripModel.selectedID?.rawValue == tab.id },
                                            report: { "the link did not reveal tab \(surface)" })
        }
    }

    @Test func aModelOutputSessionLinkCreatesNoTabAndThePersonsCreatesOne() async throws {
        try await PinnedPageTests.withApp { services, _ in
            let tabs = services.agentTabs
            try #require(tabs.canHostChat, "this build has no agent page")
            // The store request that makes a session's chat tab, recorded instead of sent.
            var created: [String?] = []
            tabs.create = { _, _, record, _, _, _ in
                created.append(record.session)
                throw CancellationError()
            }
            let session = "r8-\(UUID().uuidString.prefix(8).lowercased())"
            try #require(tabs.tab(showing: session) == nil)
            let link = try #require(services.linkText(DeepLink(.session(session, turn: nil))))

            let model = try Self.click(link, .modelOutput, services)
            #expect(model.refusal == RefusalStrings.linkTargetNotOpen(link))
            #expect(model.work.isEmpty, "a model-output link started work: \(model.work.count)")
            for _ in 0..<10 { await Task.yield() }
            #expect(created.isEmpty, "a model-output session link asked the store for a chat tab")

            let person = try Self.click(link, .person, services)
            #expect(person.refusal == nil, "refused: \(person.refusal ?? "")")
            try await PinnedPageTests.until({ created == [session] }, report: { "created: \(created)" })
        }
    }
}
