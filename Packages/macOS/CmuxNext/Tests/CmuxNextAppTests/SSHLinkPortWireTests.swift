import CmuxNextActions
@testable import CmuxNextRemote
import Foundation
import Testing
@testable import CmuxNextApp

/// The link socket's port requests (cmux-remote `AdminRequest::PortForward`, `PortList`, `PortClose`) as the app
/// writes and reads them.
@Suite struct SSHLinkPortWireTests {
    private func object(_ line: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    @Test func forwardRequestNamesPortAndLeavesUnsetFieldsOut() throws {
        let plain = try object(SSHLinkPortWire.forwardLine(port: 3000, host: nil, workspaceRoot: nil))
        #expect(plain["method"] as? String == "port-forward")
        #expect(plain["port"] as? Int == 3000)
        #expect(plain["host"] == nil)
        #expect(plain["workspace_root"] == nil)
        let scoped = try object(SSHLinkPortWire.forwardLine(port: 8080, host: "127.0.0.2", workspaceRoot: "/srv"))
        #expect(scoped["host"] as? String == "127.0.0.2")
        #expect(scoped["workspace_root"] as? String == "/srv")
        #expect(try object(SSHLinkPortWire.forwardLine(port: 1, host: "", workspaceRoot: ""))["host"] == nil)
    }

    @Test func listAndCloseRequests() throws {
        #expect(try object(SSHLinkPortWire.listLine)["method"] as? String == "port-list")
        let close = try object(SSHLinkPortWire.closeLine(port: 5173, host: nil))
        #expect(close["method"] as? String == "port-close")
        #expect(close["port"] as? Int == 5173)
        #expect(close["host"] == nil)
    }

    @Test func forwardAnswerDecodes() throws {
        let line = Data(#"{"ok":true,"result":{"port":3000,"host":"127.0.0.1","local_port":53211,"url":"http://127.0.0.1:53211/"}}"#.utf8)
        guard case .success(let forward) = SSHLinkPortWire.decode(line, SSHLinkForward.init) else { Issue.record("not a success"); return }
        #expect(forward == SSHLinkForward(port: 3000, host: "127.0.0.1", localPort: 53211, url: "http://127.0.0.1:53211/"))
        let fields = RemoteHandlers.forwardFields(forward)
        #expect(fields["local_port"] == .int(53211))
        #expect(fields["url"] == .string("http://127.0.0.1:53211/"))
    }

    @Test func listAndCloseAnswersDecode() throws {
        let list = Data(#"{"ok":true,"result":{"forwards":[{"port":1,"host":"127.0.0.1","local_port":2,"url":"u"},{"port":3,"host":"127.0.0.1","local_port":4,"url":"v"}]}}"#.utf8)
        let forwards = SSHLinkPortWire.decode(list) { ($0["forwards"] as? [[String: Any]])?.compactMap(SSHLinkForward.init) }
        guard case .success(let rows) = forwards else { Issue.record("not a success"); return }
        #expect(rows.map(\.localPort) == [2, 4])
        let closed = Data(#"{"ok":true,"result":{"port":1,"host":"127.0.0.1","closed":false}}"#.utf8)
        guard case .success(false) = SSHLinkPortWire.decode(closed, { $0["closed"] as? Bool }) else { Issue.record("closed should be false"); return }
    }

    @Test func refusalKeepsTheLinksReasonAndSilenceHasNone() {
        let refused = Data(#"{"ok":false,"error":"the machine's link is not connected yet"}"#.utf8)
        guard case .failure(let reason) = SSHLinkPortWire.decode(refused, SSHLinkForward.init) else { Issue.record("not a failure"); return }
        #expect(reason == "the machine's link is not connected yet")
        guard case .failure(let none) = SSHLinkPortWire.decode(nil, SSHLinkForward.init) else { Issue.record("not a failure"); return }
        #expect(none == nil)
        let partial = Data(#"{"ok":true,"result":{"port":1}}"#.utf8)
        guard case .failure = SSHLinkPortWire.decode(partial, SSHLinkForward.init) else { Issue.record("a partial forward decoded"); return }
    }

    @Test func portArgumentIsOneToSixtyFiveThousand() throws {
        #expect(try RemoteHandlers.portArgument(ActionInvocation(arguments: ["port": .int(3000)])) == 3000)
        #expect(try RemoteHandlers.portArgument(ActionInvocation(arguments: ["port": .string(" 8080 ")])) == 8080)
        for bad in [ActionValue.int(0), .int(65536), .string("web")] {
            #expect(throws: ActionFailure.self) { try RemoteHandlers.portArgument(ActionInvocation(arguments: ["port": bad])) }
        }
        #expect(throws: ActionFailure.self) { try RemoteHandlers.portArgument(ActionInvocation()) }
    }
}
