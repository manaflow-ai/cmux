import Foundation
import Testing
@testable import CmuxNotifications

/// Captures every JSON-RPC line the router emits so the command sequence,
/// method names, and string params can be decoded back and asserted.
@MainActor
private final class FakeFeedSocket: FeedRequestSocketLineInvoking {
    private(set) var lines: [String] = []

    func invoke(line: String) {
        lines.append(line)
    }

    /// Decodes each captured line into `(method, params)`, mirroring how the
    /// in-process socket handler re-parses the JSON (so byte ordering is moot).
    func decoded() -> [(method: String, params: [String: String])] {
        lines.map { line in
            let object = try! JSONSerialization.jsonObject(
                with: Data(line.utf8)
            ) as! [String: Any]
            let method = object["method"] as! String
            let params = (object["params"] as? [String: String]) ?? [:]
            return (method, params)
        }
    }
}

@Suite(.serialized)
@MainActor
struct FeedRequestRouterTests {
    @Test("focus issues select, focus, then flash in order")
    func focusSequence() {
        let socket = FakeFeedSocket()
        let router = FeedRequestRouter(socketInvoking: socket)

        router.routeFocus(workspaceId: "ws-1", surfaceId: "sf-1")

        let commands = socket.decoded()
        #expect(commands.count == 3)
        #expect(commands[0].method == "workspace.select")
        #expect(commands[0].params == ["workspace_id": "ws-1"])
        #expect(commands[1].method == "surface.focus")
        #expect(commands[1].params == ["surface_id": "sf-1"])
        #expect(commands[2].method == "surface.trigger_flash")
        #expect(commands[2].params == ["surface_id": "sf-1"])
    }

    @Test("send-text appends CR and sends one atomic command")
    func sendTextAppendsCarriageReturn() {
        let socket = FakeFeedSocket()
        let router = FeedRequestRouter(socketInvoking: socket)

        router.routeSendText(surfaceId: "sf-2", text: "echo hi")

        let commands = socket.decoded()
        #expect(commands.count == 1)
        #expect(commands[0].method == "surface.send_text")
        #expect(commands[0].params == ["surface_id": "sf-2", "text": "echo hi\r"])
    }

    @Test("every emitted line carries a non-empty id")
    func eachLineHasFreshId() {
        let socket = FakeFeedSocket()
        let router = FeedRequestRouter(socketInvoking: socket)

        router.routeFocus(workspaceId: "ws", surfaceId: "sf")

        let ids = socket.lines.map { line -> String in
            let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            return object["id"] as! String
        }
        #expect(ids.count == 3)
        #expect(ids.allSatisfy { !$0.isEmpty })
    }

    @Test("a command renders a decodable JSON-RPC line with a stamped id")
    func commandRendersLine() throws {
        let command = FeedRequestSocketCommand(
            method: "surface.focus",
            params: ["surface_id": "abc"]
        )
        let line = try #require(command.jsonLine(id: "fixed-id"))
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(object["id"] as? String == "fixed-id")
        #expect(object["method"] as? String == "surface.focus")
        #expect((object["params"] as? [String: String]) == ["surface_id": "abc"])
    }
}
