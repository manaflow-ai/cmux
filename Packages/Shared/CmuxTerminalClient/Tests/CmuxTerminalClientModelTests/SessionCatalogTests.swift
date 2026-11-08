import Foundation
import Testing
@testable import CmuxTerminalClientModel

/// `session.snapshot` places each terminal under the workspace that shows it,
/// which `terminal.list` alone cannot.
struct SessionCatalogTests {
    /// Two workspaces, one with a split screen, plus a terminal detached into
    /// the pool. Keys and nesting are the daemon's public snapshot's own.
    private static let snapshot = #"""
    {
      "machine": {"id": "m1"},
      "session": {"id": "s1"},
      "workspaces": [
        {"id": "ws_api", "session_id": "s1", "name": "api", "index": 0, "focused": true},
        {"id": "ws_docs", "session_id": "s1", "name": "docs", "index": 1, "focused": false}
      ],
      "screens": [
        {"id": "sc_docs", "workspace_id": "ws_docs", "name": null, "index": 0, "focused": false},
        {"id": "sc_api", "workspace_id": "ws_api", "name": null, "index": 0, "focused": true}
      ],
      "panes": [
        {"id": "pn_api_left", "screen_id": "sc_api", "name": null, "focused": true, "zoomed": false},
        {"id": "pn_api_right", "screen_id": "sc_api", "name": null, "focused": false, "zoomed": false},
        {"id": "pn_docs", "screen_id": "sc_docs", "name": null, "focused": false, "zoomed": false}
      ],
      "tabs": [
        {"id": "tab_logs", "pane_id": "pn_api_right", "name": "logs", "index": 0, "focused": false, "content_kind": "terminal", "content_id": "term_logs"},
        {"id": "tab_server", "pane_id": "pn_api_left", "name": "server", "index": 0, "focused": true, "content_kind": "terminal", "content_id": "term_server"},
        {"id": "tab_readme", "pane_id": "pn_docs", "name": "", "index": 0, "focused": false, "content_kind": "terminal", "content_id": "term_readme"}
      ],
      "terminals": [
        {"id": "term_readme", "tab_id": "tab_readme", "tab_ids": ["tab_readme"], "title": "vim README.md", "cols": 80, "rows": 24, "running": true, "lifecycle": "running", "cwd": "/home/cmux/docs"},
        {"id": "term_pool", "tab_id": null, "tab_ids": [], "title": "", "cols": 80, "rows": 24, "running": true, "lifecycle": "running"},
        {"id": "term_logs", "tab_id": "tab_logs", "tab_ids": ["tab_logs"], "title": "tail -f", "cols": 80, "rows": 24, "running": true, "lifecycle": "running"},
        {"id": "term_server", "tab_id": "tab_server", "tab_ids": ["tab_server"], "title": "npm run dev", "cols": 80, "rows": 24, "running": true, "lifecycle": "running", "cwd": "/home/cmux/api"}
      ],
      "browsers": [],
      "clients": [],
      "notifications": []
    }
    """#

    @Test func terminalsAreFiledUnderTheWorkspaceThatShowsThem() throws {
        let catalog = try TerminalCatalogDecoding.catalog(fromSnapshot: Data(Self.snapshot.utf8))
        #expect(catalog.workspaces.map(\.id) == ["ws_api", "ws_docs"])
        #expect(catalog.workspaces.map(\.name) == ["api", "docs"])
        #expect(catalog.terminals.map(\.id) == ["term_server", "term_logs", "term_readme", "term_pool"])
        #expect(catalog.terminals.map(\.workspaceID) == ["ws_api", "ws_api", "ws_docs", nil])
    }

    @Test func terminalsAreNamedLikeTheirTabs() throws {
        let catalog = try TerminalCatalogDecoding.catalog(fromSnapshot: Data(Self.snapshot.utf8))
        let byID = Dictionary(uniqueKeysWithValues: catalog.terminals.map { ($0.id, $0) })
        #expect(byID["term_server"]?.name == "server")
        #expect(byID["term_server"]?.title == "npm run dev")
        #expect(byID["term_server"]?.cwd == "/home/cmux/api")
        // An unnamed tab leaves the name empty so the title or directory shows.
        #expect(byID["term_readme"]?.name == nil)
        #expect(byID["term_readme"]?.title == "vim README.md")
        #expect(byID["term_pool"]?.name == nil)
    }

    @Test func aSnapshotWithoutLayoutRecordsStillListsEverything() throws {
        let json = #"{"workspaces":[{"id":"ws_1","name":"only"}],"terminals":[{"id":"term_1","tab_id":"tab_gone","title":"zsh"}]}"#
        let catalog = try TerminalCatalogDecoding.catalog(fromSnapshot: Data(json.utf8))
        #expect(catalog.workspaces.map(\.id) == ["ws_1"])
        #expect(catalog.terminals == [TerminalSummary(id: "term_1", title: "zsh")])
    }
}
