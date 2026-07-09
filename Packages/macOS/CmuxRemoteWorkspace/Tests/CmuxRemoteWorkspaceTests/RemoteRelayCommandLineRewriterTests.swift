import Foundation
import Testing
@testable import CmuxRemoteWorkspace

/// Behavior coverage for the alias-aware relay command-line rewriter lifted out
/// of the workspace model. Pins the JSON key classification (scalar vs array,
/// workspace vs surface vs ambiguous `tab_id`), the UUID-only match rule, the
/// no-alias / non-JSON passthrough, and the trailing-newline quirk.
@Suite("RemoteRelayCommandLineRewriter")
struct RemoteRelayCommandLineRewriterTests {
    private func decodedParams(from data: Data) throws -> [String: Any] {
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(object["params"] as? [String: Any])
    }

    private func line(_ object: [String: Any], newline: Bool = false) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        if newline {
            data.append(0x0A)
        }
        return data
    }

    @Test("scalar workspace/surface/ambiguous keys remap; arrays remap element-wise")
    func remapsScalarAndArrayKeys() throws {
        let stale = UUID()
        let workspace = UUID()
        let panel = UUID()
        let request: [String: Any] = [
            "method": "surface.report_tty",
            "params": [
                "workspace_id": stale.uuidString,
                "surface_id": stale.uuidString,
                "tab_id": stale.uuidString,
                "tab_ids": [stale.uuidString],
                "surface_ids": [stale.uuidString],
            ],
        ]
        let rewritten = RemoteRelayCommandLineRewriter.rewrite(
            try line(request),
            workspaceAliases: [stale: workspace],
            surfaceAliases: [stale: panel]
        )
        let params = try decodedParams(from: rewritten)
        #expect(params["workspace_id"] as? String == workspace.uuidString)
        #expect(params["surface_id"] as? String == panel.uuidString)
        // tab_id is ambiguous: workspace alias is tried first.
        #expect(params["tab_id"] as? String == workspace.uuidString)
        #expect(params["tab_ids"] as? [String] == [workspace.uuidString])
        #expect(params["surface_ids"] as? [String] == [panel.uuidString])
    }

    @Test("no aliases returns the input unchanged")
    func noAliasesPassesThrough() throws {
        let input = try line(["method": "x", "params": ["surface_id": UUID().uuidString]])
        let output = RemoteRelayCommandLineRewriter.rewrite(
            input,
            workspaceAliases: [:],
            surfaceAliases: [:]
        )
        #expect(output == input)
    }

    @Test("non-JSON and non-UUID values pass through untouched")
    func nonJSONAndNonUUIDPassThrough() throws {
        let stale = UUID()
        let notJSON = Data("not json".utf8)
        #expect(
            RemoteRelayCommandLineRewriter.rewrite(
                notJSON,
                workspaceAliases: [stale: UUID()],
                surfaceAliases: [:]
            ) == notJSON
        )

        let request: [String: Any] = [
            "params": ["surface_id": "not-a-uuid"],
        ]
        let input = try line(request)
        #expect(
            RemoteRelayCommandLineRewriter.rewrite(
                input,
                workspaceAliases: [:],
                surfaceAliases: [stale: UUID()]
            ) == input
        )
    }

    @Test("a trailing newline on the input is preserved on the output")
    func preservesTrailingNewline() throws {
        let stale = UUID()
        let panel = UUID()
        let request: [String: Any] = ["params": ["surface_id": stale.uuidString]]
        let rewritten = RemoteRelayCommandLineRewriter.rewrite(
            try line(request, newline: true),
            workspaceAliases: [:],
            surfaceAliases: [stale: panel]
        )
        #expect(rewritten.last == 0x0A)
        let params = try decodedParams(from: rewritten)
        #expect(params["surface_id"] as? String == panel.uuidString)
    }
}
