#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
@testable import CmuxNextBrowser
import CmuxNextWakeups
import Darwin
import Dispatch
import Foundation
import os
import Testing

/// A relaunched cmux adopts the Chromium Host a crashed cmux left (task p01-process-150): the offer and reply frames
/// are the bytes host_adoption_test.cpp checks; the socket path is the host's; a peer the trust check refuses gets
/// nothing written; an adoption hands over the socket as the control channel with the host's mint floor and fence; a
/// version mismatch and a reply that names another process start no adoption; and the supervisor adopts once per
/// launch, before it spawns, and waits for a mismatched host to end before it starts a new one.
@MainActor
@Suite struct ChromiumHostAdoptionTests {
    /// The same bytes as host_adoption_test.cpp's kGoldenOffer.
    static let goldenOffer =
        "4c0000002080000000000000050002007731050002006131010004001e0000000200080001000000000000000200080002000000"
        + "000000000200080003000000000000000200080004000000000000000100040092100000"
    /// The same bytes as host_adoption_test.cpp's kGoldenReply.
    static let goldenReply =
        "4000000021800000000000000100040001000000010004004d000000010004001f0000000100040000001000010004000000002005"
        + "001400636f6d2e636d75787465726d2e66656e63652e31"

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    private nonisolated static let plan = ChromiumHostLaunchPlan(
        configuration: ChromiumHostConfiguration(executable: URL(filePath: "/bin/sh"), arguments: []),
        remoteShim: URL(filePath: "/nonexistent/libcmux_cef_shim_remote.dylib"), frameworkLocales: ["en.lproj"])

    @Test func theOfferIsTheHostsGoldenFrame() {
        let offer = ChromiumHostAdoption.Offer(wireID: "w1", abiID: "a1", minForkAPI: 30,
                                               framework: .init(device: 1, inode: 2, size: 3, mtime: 4), appPID: 4242)
        #expect(offer.message.encoded().map(Self.hex) == Self.goldenOffer)
    }

    @Test func theHostsGoldenReplyReads() throws {
        var fds: [Int32] = []
        guard case .frame(let message, _) = ChromiumHostControlMessage.decode(Self.bytes(Self.goldenReply)[...], fds: &fds) else {
            Issue.record("the golden reply does not decode")
            return
        }
        let reply = try #require(ChromiumHostAdoption.Reply(message))
        #expect(reply.verdict == .versionMismatch && reply.hostPID == 77 && reply.forkAPI == 31)
        #expect(reply.mintFloor == ChromiumHostMintFloor(browser: 1 << 20, devtools: 1 << 29))
        #expect(reply.resizeFence == "com.cmuxterm.fence.1")
    }

    @Test func theSocketPathIsTheHosts() {
        #expect(ChromiumHostAdoption.socketPath(rootCache: "/r/", uid: 501) == "/r/chromium-host.sock")
        let long = "/Users/lawrence/Library/Application Support/com.cmuxterm.app.debug.p01-process-150-kill-app/ChromiumHost"
        #expect(ChromiumHostAdoption.socketPath(rootCache: long, uid: 501)
                    == "/tmp/cmux-chromium-host-501/\(String(format: "%016llx", ChromiumHostAdoption.fnv1a64(long))).sock")
        // FNV-1a 64 test vectors, as host_adoption_test.cpp checks them.
        #expect(ChromiumHostAdoption.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(ChromiumHostAdoption.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
    }

    /// The test process is ad-hoc signed: as a host's peer it has no team, and with none of its own cmux trusts
    /// nobody.
    @Test func anUnsignedPeerIsRefused() throws {
        var pair: [Int32] = [-1, -1]
        // SAFETY: socketpair writes two descriptors into the two-element array during the call.
        try #require(unsafe socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { pair.forEach { _ = Darwin.close($0) } }
        let peer = try #require(UnixSocketPeer(descriptor: pair[0]))
        let executable = URL(filePath: CommandLine.arguments[0])
        #expect(!ChromiumHostAdoption.trusts(peer, hostExecutable: executable, team: "ABCDE12345"))
        #expect(!ChromiumHostAdoption.trusts(peer, hostExecutable: executable, team: nil))
    }

    /// A stand-in host on a socket path: accepts one connection on a utility queue and answers it with `answer`.
    private nonisolated final class StandIn: Sendable {
        let path: String
        let listener: Int32
        /// The offer it read, nil when the connection closed before one (a refused peer).
        let offer = OSAllocatedUnfairLock<[UInt8]?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)

        init(answer: @escaping @Sendable (ChromiumHostControlMessage?) -> ChromiumHostControlMessage?) throws {
            let directory = FileManager.default.temporaryDirectory.appending(path: "adopt-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appending(path: "chromium-host.sock").path
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
            // SAFETY: the view covers exactly sun_path for the closure; the path is shorter (checked), so its NUL stays.
            unsafe withUnsafeMutableBytes(of: &address.sun_path) { unsafe $0.copyBytes(from: bytes) }
            // SAFETY: `address` is a local sockaddr_un live for the closure, passed with its whole size.
            let bound = unsafe withUnsafePointer(to: &address) { pointer in
                unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    unsafe bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0 && listen(listener, 1) == 0)
            let (listener, offer, done) = (listener, offer, done)
            DispatchQueue(label: "test.chromium-host-adoption.stand-in", qos: .utility).async {
                defer { done.signal() }
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else { return }
                defer { Darwin.close(fd) }
                var header = [UInt8](repeating: 0, count: ChromiumHostControlMessage.headerSize)
                // SAFETY: recv writes at most the array's count of bytes into the buffer it lends for the call.
                guard unsafe recv(fd, &header, header.count, MSG_WAITALL) == header.count else { return }
                let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
                var body = [UInt8](repeating: 0, count: length)
                // SAFETY: as above.
                guard length == 0 || unsafe recv(fd, &body, length, MSG_WAITALL) == length else { return }
                offer.withLock { $0 = header + body }
                var fds: [Int32] = []
                guard case .frame(let message, _) = ChromiumHostControlMessage.decode((header + body)[...], fds: &fds),
                      let reply = answer(message), let bytes = reply.encoded() else { return }
                let stream = bytes + Array("HELLO".utf8)  // the control stream right after the reply
                // SAFETY: send reads the array's bytes, which it lends for the call.
                _ = unsafe send(fd, stream, stream.count, 0)
            }
        }

        func finish() {
            done.wait()
            Darwin.close(listener)
            unlink(path)
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
    }

    private nonisolated static func reply(_ verdict: ChromiumHostAdoption.Verdict, pid: Int32 = getpid()) -> ChromiumHostControlMessage {
        let values: [ChromiumHostControlMessage.Value] = [.i32(verdict.rawValue), .i32(pid), .i32(31), .i32((1 << 20) + 9),
                                                          .i32((1 << 29) + 3), .str("fence")]
        return ChromiumHostControlMessage(op: ChromiumHostAdoption.adoptReplyOp, fields: values.map { .init(tag: 0, value: $0) })
    }

    private nonisolated static func adoption(_ path: String, trusts: Bool) -> ChromiumHostAdoption {
        ChromiumHostAdoption(socketPath: path, plan: plan,
                             offer: .init(wireID: ChromiumHostOp.wireIdentity, abiID: ChromiumHostOp.abiIdentity, minForkAPI: 30,
                                          framework: .init(device: 1, inode: 2, size: 3, mtime: 4), appPID: getpid()),
                             trusts: { _ in trusts })
    }

    @Test func anAdoptionHandsOverTheSocketWithTheMintFloor() throws {
        let host = try StandIn { _ in Self.reply(.adopted) }
        let outcome = Self.adoption(host.path, trusts: true).adopt()
        host.finish()
        guard case .adopted(let adopted) = outcome else {
            Issue.record("not adopted: \(outcome)")
            return
        }
        defer { Darwin.close(adopted.attachment.controlFD) }
        #expect(adopted.adopted && adopted.pid == getpid())
        #expect(adopted.attachment.mintFloor == ChromiumHostMintFloor(browser: (1 << 20) + 9, devtools: (1 << 29) + 3))
        #expect(adopted.attachment.resizeFence == "fence" && adopted.attachment.frameworkLocales == ["en.lproj"])
        let offer = try #require(host.offer.withLock { $0 })
        var fds: [Int32] = []
        guard case .frame(let message, _) = ChromiumHostControlMessage.decode(offer[...], fds: &fds) else {
            Issue.record("the offer does not decode")
            return
        }
        #expect(message.op == ChromiumHostAdoption.adoptOp && message.fields.count == 8)
        // Nothing past the reply was read: the control stream starts on the handed-over socket.
        var hello = [UInt8](repeating: 0, count: 5)
        // SAFETY: recv writes at most the array's count of bytes into the buffer it lends for the call.
        #expect(unsafe recv(adopted.attachment.controlFD, &hello, 5, MSG_WAITALL) == 5)
        #expect(String(decoding: hello, as: UTF8.self) == "HELLO")
    }

    @Test func anUntrustedPeerGetsNothing() throws {
        let host = try StandIn { _ in Self.reply(.adopted) }
        let outcome = Self.adoption(host.path, trusts: false).adopt()
        host.finish()
        #expect(outcome == .noHost("the process on \(host.path) is not this app's Chromium Host"))
        #expect(host.offer.withLock { $0 } == nil, "an offer went to a peer the trust check refused")
    }

    @Test func aVersionMismatchStartsNoAdoption() throws {
        let host = try StandIn { _ in Self.reply(.versionMismatch) }
        let outcome = Self.adoption(host.path, trusts: true).adopt()
        host.finish()
        #expect(outcome == .versionMismatch(hostPID: getpid()))
    }

    @Test func aReplyNamingAnotherProcessIsNotBelieved() throws {
        let host = try StandIn { _ in Self.reply(.adopted, pid: getpid() + 1) }
        let outcome = Self.adoption(host.path, trusts: true).adopt()
        host.finish()
        #expect(outcome == .noHost("the host's reply names another process"))
    }

    @Test func noSocketIsNoHost() {
        let outcome = Self.adoption("/tmp/nonexistent-\(UUID().uuidString.prefix(8)).sock", trusts: true).adopt()
        #expect(outcome == .noHost("no host waits for adoption"))
    }

    /// A spawner stand-in: what each call did, in order.
    private nonisolated final class Spawner: ChromiumHostSpawning {
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let outcome: ChromiumHostAdoption.Outcome

        init(adoption: ChromiumHostAdoption.Outcome) {
            outcome = adoption
        }

        func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
            calls.withLock { $0.append("spawn") }
            return ChromiumHostSpawn(pid: 999_999, attachment: ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/x"),
                                                                                       frameworkLocales: []))
        }
        func watchExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {
            calls.withLock { $0.append("watch \(pid)") }
        }
        func reap(_ pid: pid_t) { calls.withLock { $0.append("reap \(pid)") } }
        func kill(_ pid: pid_t) { calls.withLock { $0.append("kill \(pid)") } }
        func adopt() async -> ChromiumHostAdoption.Outcome {
            calls.withLock { $0.append("adopt") }
            return outcome
        }
        func watchAdoptedExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {
            calls.withLock { $0.append("watch adopted \(pid)") }
        }
        func awaitAdoptedEnd(of pid: pid_t, limit: Duration) async {
            calls.withLock { $0.append("await end \(pid)") }
        }
        func killAdopted(_ pid: pid_t) { calls.withLock { $0.append("kill adopted \(pid)") } }
    }

    private static let adopted = ChromiumHostSpawn(
        pid: 4321, attachment: ChromiumHostAttachment(controlFD: -1, remoteShim: URL(filePath: "/x"), frameworkLocales: [],
                                                      mintFloor: ChromiumHostMintFloor(browser: (1 << 20) + 1, devtools: 1 << 29)),
        adopted: true)

    @Test func theLaunchsFirstAttachAdoptsOnce() async throws {
        let spawner = Spawner(adoption: .adopted(Self.adopted))
        let supervisor = ChromiumHostSupervisor(spawner: spawner, survivesAppCrash: true)
        let first = try await supervisor.attachment()
        #expect(first.mintFloor == Self.adopted.attachment.mintFloor)
        #expect(supervisor.hostPID == 4321 && supervisor.hostsAdopted == 1 && supervisor.hostsStarted == 0)
        #expect(supervisor.adoption == "adopted host 4321")
        // A second attach supersedes the adopted host with a kill that checks its executable, and spawns: the
        // adoption is for the launch's first host only.
        _ = try await supervisor.attachment()
        #expect(spawner.calls.withLock { $0 } == ["adopt", "watch adopted 4321", "kill adopted 4321", "spawn", "watch 999999"])
        #expect(supervisor.hostsStarted == 1)
    }

    @Test func aMismatchedHostEndsBeforeANewOneStarts() async throws {
        let spawner = Spawner(adoption: .versionMismatch(hostPID: 4321))
        let supervisor = ChromiumHostSupervisor(spawner: spawner, survivesAppCrash: true)
        _ = try await supervisor.attachment()
        #expect(spawner.calls.withLock { $0 } == ["adopt", "await end 4321", "spawn", "watch 999999"])
        #expect(supervisor.hostsAdopted == 0 && supervisor.hostsStarted == 1)
    }

    @Test func survivalOffNeverAdopts() async throws {
        let spawner = Spawner(adoption: .adopted(Self.adopted))
        let supervisor = ChromiumHostSupervisor(spawner: spawner)
        _ = try await supervisor.attachment()
        #expect(spawner.calls.withLock { $0 } == ["spawn", "watch 999999"])
    }
}
#endif
