import CmuxSwiftRender
import SwiftUI
import Testing
@testable import CmuxSwiftRenderUI

@Suite("Custom sidebar web bridge")
struct CustomSidebarWebBridgeTests {
    @Test("parses JavaScript action payloads into sidebar actions")
    func parsesActionPayloads() throws {
        let parser = CustomSidebarWebActionParser()

        let action = try #require(parser.action(from: [
            "commands": [
                ["type": "log", "message": "hello"],
                ["type": "openURL", "url": "https://example.com"],
                ["type": "cmux", "method": "workspace.select", "params": ["workspace_id": "abc", "index": 1]],
            ],
        ] as [String: Any]))

        #expect(action.commands == [
            .log("hello"),
            .openURL("https://example.com"),
            .cmux(method: "workspace.select", params: ["workspace_id": "abc", "index": "1"]),
        ])
    }

    @Test("injects plain JSON data and native sidebar theme")
    func injectsRuntimePayload() throws {
        let script = try #require(CustomSidebarWebRuntimePayload(
            fileURL: URL(fileURLWithPath: "/tmp/status.html"),
            dataContext: [
                "selectedTitle": .string("cmux"),
                "unreadTotal": .int(3),
                "workspaces": .array([
                    .object(["title": .string("main"), "selected": .bool(true)]),
                ]),
            ],
            contentInsets: CustomSidebarContentInsets(top: 11, bottom: 17),
            colorScheme: .dark
        ).scriptSource)

        #expect(script.contains("\"selectedTitle\":\"cmux\""))
        #expect(script.contains("\"unreadTotal\":3"))
        #expect(script.contains("\"top\":11"))
        #expect(script.contains("\"bottom\":17"))
        #expect(script.contains("\"colorScheme\":\"dark\""))
        #expect(script.contains("cmuxsidebarupdate"))
        #expect(script.contains("cmuxSidebarAction"))
    }
}
