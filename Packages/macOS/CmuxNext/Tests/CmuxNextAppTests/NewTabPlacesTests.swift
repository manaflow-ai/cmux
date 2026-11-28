import CmuxNextAgentPane
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import Foundation
import Testing

/// The New Tab bar lists only places a jump lands somewhere real on (Leo 2026-10-11). It showed
/// "about:blank Home", a bare "~ ~" folder row, each workspace twice ("~ workspace-2 · ~" as a
/// terminal and "workspace-2 ~" as a workspace), and "about:blank workspace-7/8" rows for New Tab
/// pages made by rapid creates.
@MainActor
struct NewTabPlacesTests {
    private static let home = "/Users/you"
    private static var surface: UInt64 = 0

    private static func tab(_ kind: TabKind, title: String = "", url: String? = nil, cwd: String? = nil,
                            session: String?? = .none) -> TabModel {
        surface += 1
        var snapshot = TabSnapshot(surface: SurfaceID(rawValue: surface), kind: kind, title: title, url: url, cwd: cwd)
        if case .some(let session) = session {
            snapshot.conversation = ConversationTabRef(agentSession: AgentSessionRef(host: "install:places", session: session, harness: "claude"))
        }
        return TabModel(snapshot)
    }

    /// A New Tab page: a chat tab with no session yet, titled `about:blank` until it has one.
    private static func newTabPage() -> TabModel { tab(.conversation, title: "about:blank", session: .some(nil)) }

    @Test func theBarListsEachPlaceOnceWithItsOwnTitle() {
        let shell = Self.tab(.pty, title: "~", cwd: Self.home)
        let build = Self.tab(.pty, title: "cargo build", cwd: Self.home + "/src/cmux")
        let docs = Self.tab(.browser, title: "Vite Guide", url: "https://vite.dev/guide/")
        let chat = Self.tab(.conversation, title: "Fix the flaky upload test", cwd: Self.home + "/src/cmux", session: "ses-1")
        let workspaces: [NewTabPage.PlaceSource] = [
            .init(id: "w1", name: "workspace-1", tabs: [Self.newTabPage(), Self.tab(.browser, title: "Home", url: "about:blank"), build, docs, chat]),
            .init(id: "w2", name: "workspace-2", tabs: [shell]),
            .init(id: "w7", name: "workspace-7", tabs: [Self.newTabPage()]),
            .init(id: "w8", name: "workspace-8", tabs: [Self.newTabPage(), Self.tab(.pty, title: "zsh", cwd: Self.home + "/src/relay"),
                                                     Self.tab(.browser, title: "", url: "https://github.com/manaflow-ai/cmux/pull/1")]),
        ]
        let places = NewTabPage.places(workspaces, current: "w1", excluding: nil, home: Self.home)
        #expect(places.tabs.map { "\($0.kind.rawValue) \($0.title) · \($0.detail ?? "-") · \($0.workspace ?? "-")" } == [
            "terminal cargo build · ~/src/cmux · workspace-1",
            "browser Vite Guide · vite.dev/guide · workspace-1",
            "agent Fix the flaky upload test · ~/src/cmux · workspace-1",
            "terminal zsh · ~/src/relay · workspace-8",
            "browser github.com/manaflow-ai/cmux/pull/1 · - · workspace-8",
        ])
        #expect(places.workspaces.map { "\($0.name) · \($0.detail ?? "-")" } == [
            "workspace-2 · ~",
            "workspace-7 · -",
            "workspace-8 · ~/src/relay",
        ])
        #expect(places.folders == [Self.home + "/src/cmux", Self.home + "/src/relay"])
    }
}
