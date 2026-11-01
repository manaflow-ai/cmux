import AppKit
import CmuxNextActions
import CmuxNextAgentPane
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHomeEngine
import CmuxNextWakeups
import Foundation
import Testing

/// #28877: a subagent link in Chief's Home chat (`a95`, written `cmux://chief/<home id>/session/<id>`)
/// opened nothing when a named Chief (`<home>/c/<id>`) wrote it: the link names that Chief's own
/// home id, not the app's Chief host, so `DeepLink.appLink` dropped it and the click did nothing.
/// Now the click shows the tab that shows the chat, else, when that Chief home's acpmux keeps the
/// session, opens a workspace on it there; a session no Chief home keeps opens nothing and says so.
/// Through the Home click path (`CmuxAppLinks.open`, then `link.open`) on the real daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ChiefSubagentLinkOpensChatTests {
    @Test func aNamedChiefsSubagentLinkOpensItsChatOnceAndAnUnknownSessionOpensNothing() async throws {
        let homes = try Self.homes()
        defer { try? FileManager.default.removeItem(at: homes.base) }
        let namedHost = ChiefHome.tabHost(muxHome: homes.named)
        let namedID = namedHost.dropFirst(ChiefHome.tabHostPrefix.count)
        // The named Chief's sessions run in its home's acpmux (`<home>/acpmux`), as on a real Mac.
        let session = try Self.keep(in: homes.app)

        try await Self.withChief(homes) { services, refusals in
            let tabs = services.agentTabs
            #expect(namedHost != tabs.chiefHost)
            let link = try #require(URL(string: "cmux://chief/\(namedID)/session/\(session)"))
            Self.ownChiefSidebar(services)
            #expect(CmuxAppLinks.open(link, services: services), "the click was dropped")
            try await PinnedPageTests.until({ tabs.tab(showing: session, host: namedHost) != nil }, within: .seconds(30),
                                            report: { "no tab shows \(session) on \(namedHost); refusals \(refusals())" })
            let shown = try #require(tabs.tab(showing: session, host: namedHost))
            #expect(services.locateTabOnAnyMachine(shown)?.0.kind == .conversation)

            // A second click shows that tab (synchronously, no disk read), never a second workspace.
            Self.ownChiefSidebar(services)
            #expect(CmuxAppLinks.open(link, services: services))
            #expect(Self.tabs(showing: session, services) == 1)

            // A session no Chief home keeps opens nothing, and says so.
            let stray = "01a19008-0000-7000-8000-\(UUID().uuidString.suffix(12).lowercased())"
            let unknown = try #require(URL(string: "cmux://chief/\(namedID)/session/\(stray)"))
            let before = refusals().count
            Self.ownChiefSidebar(services)
            #expect(CmuxAppLinks.open(unknown, services: services))
            try await PinnedPageTests.until({ refusals().dropFirst(before).contains(ChiefToolStrings.noSubagent) },
                                            report: { "the stray link did not refuse: \(refusals().dropFirst(before))" })
            #expect(Self.tabs(showing: stray, services) == 0, "a link to a session no Chief keeps opened a chat")
        }
    }

    private struct Homes {
        let base: URL
        /// The app's Chief home (`<root>/default`).
        let app: URL
        /// A named Chief's home inside it (`<root>/default/c/<id>`).
        let named: URL
    }

    private static func homes() throws -> Homes {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cn-chief-link-\(UUID().uuidString.prefix(8))")
        let app = base.appendingPathComponent("default", isDirectory: true)
        let named = app.appendingPathComponent("c", isDirectory: true).appendingPathComponent("dbh2607j", isDirectory: true)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        return Homes(base: base, app: app, named: named)
    }

    /// A new session id that Chief home `home`'s acpmux keeps on disk (`acpmux/sessions/<id>`).
    private static func keep(in home: URL) throws -> String {
        let session = "01a19008-7a62-72f3-91b5-\(UUID().uuidString.suffix(12).lowercased())"
        let dir = home.appendingPathComponent("acpmux/sessions/\(session)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return session
    }

    /// The app on the real daemon with `homes`' Chief (the app's own home, and the Chief root that
    /// holds the named Chief), and every refusal the app reports.
    private static func withChief(_ homes: Homes, _ body: (AppServices, () -> [String]) async throws -> Void) async throws {
        try await PinnedPageTests.withApp { services, _ in
            let tabs = services.agentTabs
            tabs.localHost = AgentSessionRef.host(installID: "chief-link-test")
            tabs.holdsTabs = { _ in true }
            tabs.chiefHost = ChiefHome.tabHost(muxHome: homes.app)
            // The host the app wires (AgentTabs+Wiring): an acpmux host on the app's own daemons.
            tabs.chiefHomes = ChiefHomeDirectory(parents: [homes.base], work: BackgroundWork(), environment: { _ in nil }) {
                [daemons = services.acpmuxDaemons, peerApprover = tabs.peerApprover] in
                AcpmuxHost(daemons: daemons, environment: $0, startsDaemons: $1, peerApprover: peerApprover)
            }
            try #require(tabs.canHostChat, "this build has no agent page")
            let refusals = Refusals()
            let shown = services.registry.refusalObserver
            services.registry.refusalObserver = { reason, quiet in
                refusals.all.append(reason)
                shown?(reason, quiet)
            }
            defer { services.registry.refusalObserver = shown }
            try await body(services, { refusals.all })
        }
    }

    @MainActor private final class Refusals { var all: [String] = [] }

    /// Binds the app-wide `ChiefSidebar.shared` to this test's app again just before a click: another
    /// suite's app, running at the same time in the parallel pass, may have bound it since.
    private static func ownChiefSidebar(_ services: AppServices) {
        SidebarSectionHandlers.bind(into: services.registry, context: AppActionContext(services: services))
    }

    /// The tabs in every workspace whose chat is `session`, whatever host they record.
    private static func tabs(showing session: String, _ services: AppServices) -> Int {
        services.agentTabs.listTabs().filter { (services.agentTabs.session(of: $0.key) ?? $0.record.session) == session }.count
    }
}
