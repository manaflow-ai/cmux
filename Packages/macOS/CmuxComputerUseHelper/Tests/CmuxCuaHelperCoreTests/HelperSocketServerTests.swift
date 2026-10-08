// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct HelperSocketServerTests {
    func server(_ inspector: any PeerInspecting, tools: FakeTools = FakeTools(),
                admission: AdmissionState? = nil) throws -> (HelperSocketServer, String) {
        let state = admission ?? {
            let state = AdmissionState()
            state.configure(config())
            return state
        }()
        let path = makeSocketDirectory() + "/h.sock"
        let server = HelperSocketServer(path: path, admission: state, inspector: inspector, tools: tools)
        try server.start()
        return (server, path)
    }

    /// The `nc -U` case with the real kernel inspector: this test process is
    /// a same-uid peer that is not acpmux, so it is refused before it sends anything.
    @Test func plainSameUserClientIsRefusedWithoutSendingAnything() throws {
        let (server, path) = try server(KernelPeerInspector())
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        let reply = try #require(client.receive())
        #expect(reply["ok"] as? Bool == false)
        #expect(reply["error"] as? String == "refused")
        #expect(client.atEOF())
    }

    @Test func socketFileIsOwnerOnly() throws {
        let (server, path) = try server(KernelPeerInspector())
        defer { server.stop() }
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        var directory = stat()
        #expect(lstat((path as NSString).deletingLastPathComponent, &directory) == 0)
        #expect(directory.st_mode & 0o777 == 0o700)
    }

    /// Required test 1 at the socket: valid acpmux code outside the registered tree.
    @Test func acpmuxCodeOutsideTheTreeIsRefusedAtAccept() throws {
        let outside = acpmuxBridge(ancestors: [ProcessStamp(pid: 777, startSeconds: 1, startMicroseconds: 0)])
        let (server, path) = try server(FixedInspector(peer: outside))
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        let reply = try #require(client.receive())
        #expect(reply["reason"] as? String == "outside_acpmux_tree")
        #expect(client.atEOF())
    }

    /// Required test 2 at the socket.
    @Test func wrongCDHashIsRefusedAtAccept() throws {
        let (server, path) = try server(FixedInspector(peer: acpmuxBridge(cdhash: otherHash)))
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        #expect(client.receive()?["reason"] as? String == "unknown_code")
        #expect(client.atEOF())
    }

    /// Required test 3 at the socket: identity passes, the first line has no secret.
    @Test func missingSecretIsRefused() throws {
        let tools = FakeTools()
        let (server, path) = try server(FixedInspector(peer: acpmuxBridge()), tools: tools)
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        client.send(#"{"id":1,"method":"tools/call","name":"click","arguments":{}}"# + "\n")
        #expect(client.receive()?["reason"] as? String == "missing_secret")
        #expect(client.atEOF())
        #expect(tools.calls.withLock { $0 }.isEmpty)
    }

    @Test func wrongSecretIsRefused() throws {
        let (server, path) = try server(FixedInspector(peer: acpmuxBridge()))
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        client.send(#"{"secret":"\#(HelperWire.hex(Data(repeating: 9, count: 32)))"}"# + "\n")
        #expect(client.receive()?["reason"] as? String == "wrong_secret")
    }

    @Test func admittedBridgeListsAndCallsTools() throws {
        let tools = FakeTools()
        let (server, path) = try server(FixedInspector(peer: acpmuxBridge()), tools: tools)
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        client.send(#"{"secret":"\#(HelperWire.hex(secret))"}"# + "\n")
        let hello = try #require(client.receive())
        #expect(hello["ok"] as? Bool == true)
        #expect(hello["protocol"] as? Int == 1)
        client.send(#"{"id":7,"method":"tools/list"}"# + "\n")
        let list = try #require(client.receive())
        #expect(list["id"] as? Int == 7)
        #expect(((list["result"] as? [String: Any])?["tools"] as? [Any])?.count == 1)
        client.send(#"{"id":8,"method":"tools/call","name":"click","arguments":{"element_token":"s0000000a:3"}}"# + "\n")
        let call = try #require(client.receive())
        #expect(call["id"] as? Int == 8)
        #expect(call["ok"] as? Bool == true)
        #expect(tools.calls.withLock { $0 } == [#"click {"element_token":"s0000000a:3"}"#])
    }

    @Test func unconfiguredHelperRefusesEveryone() throws {
        let (server, path) = try server(FixedInspector(peer: acpmuxBridge()), admission: AdmissionState())
        defer { server.stop() }
        let client = try #require(TestClient(path: path))
        #expect(client.receive()?["reason"] as? String == "not_configured")
    }

    @Test func symlinkedSocketDirectoryIsRejected() throws {
        let real = makeSocketDirectory()
        let link = real + "-link"
        symlink(real, link)
        let server = HelperSocketServer(path: link + "/h.sock", admission: AdmissionState(),
                                        inspector: KernelPeerInspector(), tools: FakeTools())
        #expect(throws: HelperSocketServer.StartError.directoryNotPrivate(link)) { try server.start() }
    }
}
