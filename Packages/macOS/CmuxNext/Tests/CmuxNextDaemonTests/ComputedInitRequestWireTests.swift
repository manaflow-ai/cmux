import Foundation
import Testing
@testable import CmuxNextDaemon

/// The exact request lines of the tab requests whose inits do work (`new-remote-terminal-tab` takes a
/// `RemoteTerminalRef` and a `CellSize`, `new-frontend-browser-tab` a `CellSize` and sets its
/// `idempotency_key` only in `send(on:)`). These bytes are the contract the generated types (swift_app
/// request `init`) keep with the hand-written ones they replaced.
struct ComputedInitRequestWireTests {
    private func line(_ request: some DaemonRequest) throws -> String {
        String(decoding: try WireCoding.encodeRequest(request, id: 7), as: UTF8.self)
    }

    private static let ref = RemoteTerminalRef(sessionID: "s1", terminalID: "t1", sessionName: "box")

    @Test func aRemoteTerminalTabSendsItsRefAndSize() throws {
        #expect(try line(NewRemoteTerminalTabRequest(Self.ref, pane: 3, title: "top", size: CellSize(cols: 80, rows: 24)))
            == #"{"cmd":"new-remote-terminal-tab","cols":80,"id":7,"pane":3,"rows":24,"session_id":"s1","session_name":"box","terminal_id":"t1","title":"top"}"#)
    }

    @Test func aPlainRemoteTerminalTabSendsItsRefAlone() throws {
        #expect(try line(NewRemoteTerminalTabRequest(Self.ref))
            == #"{"cmd":"new-remote-terminal-tab","id":7,"session_id":"s1","session_name":"box","terminal_id":"t1"}"#)
    }

    @Test func aBrowserTabSendsEveryFieldItSets() throws {
        var request = NewFrontendBrowserTabRequest(
            url: "https://example.org/", engine: .cef, pane: 3, title: "t", faviconURL: "f", profileID: "default",
            size: CellSize(cols: 80, rows: 24), activate: false, after: 5,
            split: ConversationTabSplit(direction: .right, paneID: "p1", splitID: "s1"))
        request.idempotencyKey = "k"
        #expect(try line(request)
            == #"{"activate":false,"after":5,"cmd":"new-frontend-browser-tab","cols":80,"engine":"cef","favicon_url":"f","id":7,"idempotency_key":"k","pane":3,"profile_id":"default","rows":24,"split":{"direction":"right","pane_id":"p1","split_id":"s1"},"title":"t","url":"https://example.org/"}"#)
    }

    @Test func aPlainBrowserTabSendsItsURLAndEngine() throws {
        let request = NewFrontendBrowserTabRequest(url: "https://example.org/", engine: .webkit)
        #expect(request.idempotencyKey == nil)
        #expect(try line(request) == #"{"cmd":"new-frontend-browser-tab","engine":"webkit","id":7,"url":"https://example.org/"}"#)
    }

    @Test func aWorkspaceBrowserTabNamesTheWorkspace() throws {
        #expect(try line(NewFrontendBrowserTabRequest(url: "u", engine: .webkit, workspace: WorkspaceHandle(rawValue: 4)))
            == #"{"cmd":"new-frontend-browser-tab","engine":"webkit","id":7,"url":"u","workspace":4}"#)
    }
}
