import Foundation
import Testing
@testable import CmuxNextApp

/// The memory inspector's endpoint file: only a loopback address is
/// trusted, and the page URL carries a one-time ticket, never the token.
@Suite struct ChiefInspectorEndpointTests {
    private func home(with json: String?) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("chief-inspector-\(UUID().uuidString)")
        let dir = home.appendingPathComponent("optchat")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let json { try Data(json.utf8).write(to: dir.appendingPathComponent("inspector.json")) }
        return home
    }

    @Test @MainActor func readsTheLoopbackEndpoint() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let home = try home(with: #"{"url":"http://127.0.0.1:52011/","token":"\#(String(repeating: "a", count: 64))","pid":\#(pid)}"#)
        let endpoint = try ChiefInspectorEndpoint.read(muxHome: home)
        #expect(endpoint.url.port == 52011)
        let page = ChiefInspectorEndpoint.pageURL(base: endpoint.url, ticket: "t1")
        #expect(page.absoluteString == "http://127.0.0.1:52011/?ticket=t1")
        #expect(!page.absoluteString.contains(endpoint.token))
    }

    @Test @MainActor func refusesAMissingFileOrANonLoopbackHost() throws {
        #expect(throws: (any Error).self) { try ChiefInspectorEndpoint.read(muxHome: try home(with: nil)) }
        let remote = try home(with: #"{"url":"http://10.0.0.5:52011/","token":"x"}"#)
        #expect(throws: (any Error).self) { try ChiefInspectorEndpoint.read(muxHome: remote) }
        // A host that exited leaves a stale file: its token is never sent.
        let stale = try home(with: #"{"url":"http://127.0.0.1:52011/","token":"x","pid":2147483000}"#)
        #expect(throws: (any Error).self) { try ChiefInspectorEndpoint.read(muxHome: stale) }
    }
}
