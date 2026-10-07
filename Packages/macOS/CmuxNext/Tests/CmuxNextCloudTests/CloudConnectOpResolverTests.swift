@testable import CmuxNextCloud
import Darwin
import Foundation
import Testing

/// Adapter 1: the socket comes from the Cloud app server's
/// `cloud.machine.connect` answer, and only an owner-only socket is used.
@Suite(.serialized) struct CloudConnectOpResolverTests {
    let key = CloudLinkKey(machine: "vm_1")

    @Test func theKeyIsTheAppAndTheMachine() {
        #expect(key.description == "cmux/cloud/vm_1")
        #expect(CloudLinkKey(app: "cmux/cloud", target: "vm_1") == key)
        #expect(CloudLinkKey(app: "cmux/other", target: "vm_1") == nil)
        #expect(CloudLinkKey(app: "cmux/cloud", target: "") == nil)
    }

    @Test func connectRunsTheConnectOpAndReturnsTheCarrierSocket() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let ops = FakeCloudAppOps(socket: socket.path, generation: 4)
        let resolver = CloudConnectOpResolver(run: ops.runner)
        let opened = try await resolver.open(key, intent: "k1", origin: .user)
        #expect(opened == CloudLinkSocket(key: key, path: socket.path, generation: 4))
        #expect(ops.recorded == [.init(op: "cloud.machine.connect", args: ["machine": "vm_1"], key: "k1", origin: .user)])
    }

    @Test func anAnswerForAnotherMachineIsRefused() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let ops = FakeCloudAppOps { _ in
            Data(#"{"machine":"vm_2","state":"up","generation":1,"socket":"\#(socket.path)"}"#.utf8)
        }
        await #expect(throws: CloudLinkError.self) {
            _ = try await CloudConnectOpResolver(run: ops.runner).open(key, intent: "k", origin: .user)
        }
    }

    @Test func anAnswerWithoutASocketIsRefused() async throws {
        let ops = FakeCloudAppOps { _ in Data(#"{"machine":"vm_1","state":"up","generation":1}"#.utf8) }
        let error = await #expect(throws: CloudLinkError.self) {
            _ = try await CloudConnectOpResolver(run: ops.runner).open(key, intent: "k", origin: .user)
        }
        guard case .invalidAnswer = error else { Issue.record("expected invalidAnswer, got \(String(describing: error))"); return }
    }

    @Test func aSocketInADirectoryOthersCanReadIsRefused() async throws {
        let socket = try TestLinkSocket(directoryMode: 0o755)
        defer { socket.remove() }
        let error = await #expect(throws: CloudLinkError.self) {
            _ = try await CloudConnectOpResolver(run: FakeCloudAppOps(socket: socket.path).runner).open(key, intent: "k", origin: .user)
        }
        guard case .unsafeSocket = error else { Issue.record("expected unsafeSocket, got \(String(describing: error))"); return }
    }

    @Test func pathsThatAreNotAnOwnedCarrierSocketAreRefused() throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let file = socket.directory + "/cmux-link-111111111111.sock"
        #expect(FileManager.default.createFile(atPath: file, contents: Data()))
        defer { unlink(file) }
        let link = socket.directory + "/cmux-link-222222222222.sock"
        #expect(symlink(socket.path, link) == 0)
        defer { unlink(link) }
        let dotted: String = socket.directory + "/../" + String(socket.directory.dropFirst(5)) + "/cmux-link-0123456789ab.sock"
        let missing: String = socket.directory + "/cmux-link-333333333333.sock"
        let long: String = "/" + String(repeating: "a", count: 80) + "/cmux-link-0123456789ab.sock"
        let paths: [String] = ["", "relative/cmux-link-0123456789ab.sock", file, link, dotted, missing, long,
                               socket.directory + "//cmux-link-0123456789ab.sock"]
        for path in paths {
            #expect(throws: CloudLinkError.self, "\(path)") { try CloudLinkSocketPolicy.check(path) }
        }
        try CloudLinkSocketPolicy.check(socket.path)
        // Another user's socket (the check takes the uid to compare with).
        #expect(throws: CloudLinkError.self) { try CloudLinkSocketPolicy.check(socket.path, uid: getuid() + 1) }
    }

    @Test func aSocketThatIsNotACarrierIsRefused() throws {
        // For example the local daemon's socket in an owner-only directory.
        for name in ["daemon.sock", "cmux-link-0123456789AB.sock", "cmux-link-0123.sock"] {
            let socket = try TestLinkSocket(name: name)
            defer { socket.remove() }
            #expect(throws: CloudLinkError.self, "\(name)") { try CloudLinkSocketPolicy.check(socket.path) }
        }
    }

    @Test func linkErrorsFromTheServerKeepTheirMeaning() async throws {
        for (code, expected) in [("cmux.cloud.link_revoked", "revoked"), ("cmux.cloud.link_down", "disconnected"),
                                 ("cmux.cloud.link_unavailable", "disconnected"), ("cloud.quota.exceeded", "failed")] {
            let ops = FakeCloudAppOps { _ in throw CloudAppOpError(code: code, message: "m") }
            let error = await #expect(throws: CloudLinkError.self) {
                _ = try await CloudConnectOpResolver(run: ops.runner).open(key, intent: "k", origin: .script)
            }
            let kind = switch error {
            case .revoked?: "revoked"
            case .disconnected?: "disconnected"
            case .failed(let failedCode, _)?: failedCode == code ? "failed" : "wrong code"
            default: "other"
            }
            #expect(kind == expected, "\(code)")
        }
    }

    @Test func closeRunsTheDisconnectOp() async {
        let ops = FakeCloudAppOps { _ in Data(#"{"machine":"vm_1","disconnected":true}"#.utf8) }
        await CloudConnectOpResolver(run: ops.runner).close(key)
        #expect(ops.recorded.map(\.op) == ["cloud.machine.disconnect"])
        #expect(ops.recorded.first?.args == ["machine": "vm_1"])
    }

    @Test func theTerminalLinkSourceIsNotAvailableYet() async {
        await #expect(throws: CloudLinkError.unsupported) {
            _ = try await CloudTerminalLinkResolver().open(key, intent: "k", origin: .user)
        }
    }
}
