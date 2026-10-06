import Foundation
import Testing
@testable import CmuxNextAgentPane

/// C1 (ad349): a page frame never makes the harness spawn a command. `mcpServers` entries carry
/// {command, args, env}; no configured-server list exists, so any entry is refused, in every
/// allowed method and at any depth. An empty list (what the pane sends) passes.
@Suite struct AcpmuxPaneMethodsCommandTests {
    private func frame(_ method: String, _ params: [String: Any], id: Int? = 3) -> String {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { object["id"] = id }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static let server: [[String: Any]] = [["name": "x", "command": "/bin/sh", "args": ["-c", "id"], "env": []]]

    @Test func anMcpServerEntryIsRefusedInEveryAllowedMethod() {
        for method in AcpmuxPaneMethods.requests {
            let text = frame(method, ["sessionId": "s", "mcpServers": Self.server])
            #expect(AcpmuxPaneMethods.decide(text, isFirst: false, localAppToken: nil)
                == .refuse(.mcpServersRefused, method: method, requestID: "3"), "\(method)")
        }
        #expect(AcpmuxPaneMethods.decide(frame("session/cancel", ["sessionId": "s", "mcpServers": Self.server], id: nil),
                                         isFirst: false, localAppToken: nil)
            == .refuse(.mcpServersRefused, method: "session/cancel", requestID: nil))
    }

    @Test func aNestedEntryIsRefusedToo() {
        let nested = frame("_acpmux/handoff_start", ["handoffId": "h", "target": ["harness": "codex", "mcpServers": Self.server]])
        #expect(AcpmuxPaneMethods.decide(nested, isFirst: false, localAppToken: nil)
            == .refuse(.mcpServersRefused, method: "_acpmux/handoff_start", requestID: "3"))
        let fork = frame("acp.session.fork", ["sessionId": "s", "_meta": ["acpmux": ["mcpServers": Self.server]]])
        #expect(AcpmuxPaneMethods.decide(fork, isFirst: false, localAppToken: nil)
            == .refuse(.mcpServersRefused, method: "acp.session.fork", requestID: "3"))
        // Not a list at all is refused as well.
        let odd = frame("session/new", ["mcpServers": ["command": "/bin/sh"]])
        #expect(AcpmuxPaneMethods.decide(odd, isFirst: false, localAppToken: nil)
            == .refuse(.mcpServersRefused, method: "session/new", requestID: "3"))
        // The first frame too.
        let hello = frame("initialize", ["mcpServers": Self.server], id: 0)
        #expect(AcpmuxPaneMethods.decide(hello, isFirst: true, localAppToken: nil)
            == .refuse(.mcpServersRefused, method: "initialize", requestID: "0"))
    }

    @Test func theEmptyListThePaneSendsPasses() {
        let text = frame("session/new", ["cwd": "/tmp", "mcpServers": [Any]()])
        #expect(AcpmuxPaneMethods.decide(text, isFirst: false, localAppToken: nil) == .send(text))
    }
}
