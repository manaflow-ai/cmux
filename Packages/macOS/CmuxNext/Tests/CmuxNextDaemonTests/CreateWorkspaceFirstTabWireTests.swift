import Foundation
import Testing
@testable import CmuxNextDaemon

/// A new browser workspace is one daemon request (`workspace-first-tab-v1`): `create-workspace`
/// carries its first browser tab and the reply names the tab. It was four requests
/// (`create-workspace`, `create-terminal`, `new-frontend-browser-tab`, `close-tab`), so the window
/// showed a terminal first (Lawrence 2026-11-10: "I make a new browser workspace and then it makes
/// a new terminal").
struct CreateWorkspaceFirstTabWireTests {
    private static let key = WorkspaceKey(rawValue: "018f6e21-7b70-7e70-8000-0000000000b1")

    @Test func theCreateCarriesItsFirstBrowserTab() throws {
        let tab = WorkspaceFirstBrowserTab(url: "https://example.com/", engine: .cef, title: "Example", profileID: "default", idempotencyKey: "tab-key")
        let request = CreateWorkspaceRequest(name: "web", key: Self.key, firstTab: tab, mutation: nil)
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 7))
        guard case .object(let fields) = value else {
            Issue.record("not an object: \(value)")
            return
        }
        #expect(fields["cmd"] == .string("create-workspace"))
        #expect(fields["key"] == .string(Self.key.rawValue))
        #expect(fields["first_tab"] == .object([
            "kind": .string("browser"), "url": .string("https://example.com/"), "engine": .string("cef"),
            "title": .string("Example"), "profile_id": .string("default"), "idempotency_key": .string("tab-key"),
        ]))
    }

    /// A create with no first tab sends the request an older daemon knows: no `first_tab` field at all.
    @Test func aPlainCreateSendsNoFirstTab() throws {
        let request = CreateWorkspaceRequest(name: nil, key: Self.key, mutation: nil)
        let value = try JSONDecoder().decode(JSONValue.self, from: WireCoding.encodeRequest(request, id: 8))
        guard case .object(let fields) = value else {
            Issue.record("not an object: \(value)")
            return
        }
        #expect(fields["first_tab"] == nil)
    }

    @Test func theReplyNamesTheTabItMade() throws {
        let reply = #"{"workspace":4,"key":"018f6e21-7b70-7e70-8000-0000000000b1","index":2,"workspace_revision":9,"replayed":false,"first_tab":{"surface":12,"tab_resource_id":"tab_0123456789abcdef0123456789abcdef","replayed":false}}"#
        let result = try JSONDecoder().decode(WorkspaceMutationResult.self, from: Data(reply.utf8))
        #expect(result.firstTab?.surface == SurfaceID(rawValue: 12))
        #expect(result.firstTab?.tabResourceID?.rawValue == "tab_0123456789abcdef0123456789abcdef")
        // An older daemon's reply has no first tab.
        let old = #"{"workspace":4,"key":"018f6e21-7b70-7e70-8000-0000000000b1","workspace_revision":9,"replayed":false}"#
        #expect(try JSONDecoder().decode(WorkspaceMutationResult.self, from: Data(old.utf8)).firstTab == nil)
    }
}
