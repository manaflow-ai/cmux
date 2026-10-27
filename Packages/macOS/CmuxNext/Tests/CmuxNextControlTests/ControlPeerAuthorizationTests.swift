@testable import CmuxNextControl
import CmuxFuzzSupport
import CmuxNextSettings
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing

/// The control socket's authorization over its peer seams (p15-oracle-135): ``ControlPeerCredentials`` reads the
/// client's uid and pid (`getpeereid`/`LOCAL_PEERPID` on Darwin, `SO_PEERCRED` on Linux) and
/// ``ControlPeerAncestry`` its ancestors (`sysctl` on Darwin, procfs on Linux). The rules are the same on both:
/// a peer whose facts cannot be read is denied in every mode, another user's peer is denied, and `cmuxOnly`
/// admits only a descendant of the app or of a process running a trusted executable.
@Suite struct ControlPeerAuthorizationTests {
    static let trusted = "/Applications/cmux.app/Contents/Resources/bin/cmux"
    static let app: pid_t = 500

    func admitted(_ mode: ControlAccessMode, _ peer: ControlSocketServer.Peer, _ ancestry: ControlPeerAncestry,
                  executables: Set<String> = [trusted]) -> Bool {
        let configuration = ControlSocketServer.Configuration(path: "/unused", accessMode: mode, trustedAncestor: Self.app,
                                                              trustedExecutables: executables)
        return ControlAuthorizer(configuration: configuration, peer: peer, ancestry: ancestry).isPeerAdmitted
    }

    /// Every process descends from the app: only the peer's own facts can deny it.
    let everyoneInside = ControlPeerAncestry { _ in (parent: ControlPeerAuthorizationTests.app, executable: nil) }

    @Test func aPeerWithUnknownFactsIsDeniedInEveryMode() {
        let me = getuid()
        for mode in [ControlAccessMode.off, .automation, .cmuxOnly] {
            #expect(!admitted(mode, .init(pid: nil, uid: nil), everyoneInside), "\(mode): nothing known")
            #expect(!admitted(mode, .init(pid: 42, uid: nil), everyoneInside), "\(mode): no uid")
        }
        #expect(!admitted(.cmuxOnly, .init(pid: nil, uid: me), everyoneInside), "cmuxOnly: no pid")
        #expect(admitted(.automation, .init(pid: nil, uid: me), everyoneInside), "automation needs only the uid")
        #expect(admitted(.cmuxOnly, .init(pid: 42, uid: me), everyoneInside))
    }

    @Test func anotherUsersPeerIsDenied() {
        let other = getuid() &+ 1
        #expect(!admitted(.automation, .init(pid: 42, uid: other), everyoneInside))
        #expect(!admitted(.cmuxOnly, .init(pid: 42, uid: other), everyoneInside))
    }

    @Test func aPeerWhoseProcessIsGoneIsDenied() {
        let gone = ControlPeerAncestry { _ in nil }
        #expect(!admitted(.cmuxOnly, .init(pid: 42, uid: getuid()), gone))
    }

    /// Random process tables (cycles, missing entries, pid 1, negative parents) and random peers: `cmuxOnly`
    /// admits exactly the peers whose chain of parents, read until it ends, repeats or loses a process, holds
    /// the app or a trusted executable above the peer itself; every other mode and fact follows its rule.
    @Test func authorizationFollowsItsRulesOnRandomProcessTables() throws {
        let me = getuid()
        try FuzzRun("ControlPeerAuthorization.tables", seed: 0xC0_135, iterations: 2_000).forEach { rng in
            var table: [pid_t: (parent: pid_t, executable: String?)] = [:]
            let pids = (0..<rng.int(in: 0...12)).map { _ in pid_t(rng.int(in: -1...20)) } + [Self.app]
            for pid in pids where rng.below(5) != 0 {
                let parent = rng.oneIn(6) ? pid_t(rng.int(in: -2...1)) : pids[rng.below(pids.count)]
                let executable = rng.element(of: [nil, "/bin/zsh", Self.trusted, Self.trusted + " (deleted)"]) ?? nil
                table[pid] = (parent, executable)
            }
            let snapshot = table
            let ancestry = ControlPeerAncestry { snapshot[$0] }
            let pid: pid_t? = rng.oneIn(8) ? nil : pids[rng.below(pids.count)]
            let uid: uid_t? = rng.oneIn(8) ? nil : (rng.oneIn(4) ? me &+ 1 : me)
            let peer = ControlSocketServer.Peer(pid: pid, uid: uid)

            let expected = uid == me && pid.map { Self.reachesTrust(from: $0, in: snapshot) } == true
            try FuzzRun.check(admitted(.cmuxOnly, peer, ancestry) == expected, "cmuxOnly \(peer) over \(snapshot)")
            try FuzzRun.check(admitted(.automation, peer, ancestry) == (uid == me), "automation \(peer)")
            try FuzzRun.check(!admitted(.off, peer, ancestry), "off admitted \(peer)")
        }
    }

    /// The model: the peer's chain of parents, stopped at pid 1 or below, a missing process, a negative parent or
    /// the first repeat, holds the app, or a trusted executable on a process other than the peer itself.
    static func reachesTrust(from pid: pid_t, in table: [pid_t: (parent: pid_t, executable: String?)]) -> Bool {
        var seen: Set<pid_t> = []
        var current = pid
        while seen.insert(current).inserted {
            if current == app { return true }
            guard current > 1, let process = table[current] else { return false }
            if current != pid, process.executable == trusted { return true }
            guard process.parent >= 0 else { return false }
            current = process.parent
        }
        return false
    }

    // MARK: - procfs

    /// A fake procfs at a temporary root: `<root>/<pid>/stat` and the `<root>/<pid>/exe` link.
    func procfsRoot(_ processes: [(pid: pid_t, stat: String, exe: String?)]) throws -> String {
        let root = NSTemporaryDirectory() + "cpa-\(UUID().uuidString.prefix(8).lowercased())"
        for process in processes {
            let directory = "\(root)/\(process.pid)"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try Data(process.stat.utf8).write(to: URL(fileURLWithPath: directory + "/stat"))
            if let exe = process.exe { try FileManager.default.createSymbolicLink(atPath: directory + "/exe", withDestinationPath: exe) }
        }
        return root
    }

    @Test func procfsAncestryReadsParentsAndExecutables() throws {
        let root = try procfsRoot([
            (10, "10 (zsh) S 7 10 10 0 -1 4194560", "/bin/zsh"),
            (7, "7 (cmux (host) x) S 1 7 7 0 -1", Self.trusted),
            (11, "11 (sh) S 10", nil),
            (12, "12 garbage", "/bin/sh"),
        ])
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ancestry = ControlPeerAncestry.procfs(root: root)
        #expect(ancestry.lookup(10)?.parent == 7)
        #expect(ancestry.lookup(10)?.executable == "/bin/zsh")
        #expect(ancestry.lookup(7)?.parent == 1, "a command name with spaces and parentheses")
        #expect(ancestry.lookup(11)?.parent == 10)
        #expect(ancestry.lookup(11)?.executable == nil, "an unreadable exe link is no executable")
        #expect(ancestry.lookup(12) == nil, "a malformed stat is a gone process")
        #expect(ancestry.lookup(13) == nil, "a missing process")
        #expect(ancestry.isInside(11, ancestor: Self.app, executables: [Self.trusted]), "below the trusted host")
        #expect(!ancestry.isInside(7, ancestor: Self.app, executables: [Self.trusted]), "the trusted host itself")
        #expect(!ancestry.isInside(12, ancestor: Self.app, executables: [Self.trusted]))
    }

    @Test func statLinesParseTheirParent() {
        func parent(_ line: String) -> pid_t? { ControlPeerAncestry.parentPID(stat: Array(line.utf8)) }
        #expect(parent("1 (init) S 0 1 1") == 0)
        #expect(parent("42 (a) b) c) R 41 42") == 41)
        #expect(parent("42 (x) S") == nil)
        #expect(parent("42 (x) S -3 1") == nil)
        #expect(parent("42 (x) SS 3 1") == nil)
        #expect(parent("42 x S 3") == nil)
        #expect(parent("") == nil)
    }

    @Test func anyStatBytesParseOrAreRefused() throws {
        let alphabet: [Character] = ["(", ")", " ", "S", "1", "9", "-", "x", "\n"]
        try FuzzRun("ControlPeerAncestry.stat", seed: 0xC0_136, iterations: 3_000).forEach { rng in
            let ppid = pid_t(rng.int(in: 0...99_999))
            let comm = rng.text(alphabet, 15)
            try FuzzRun.check(ControlPeerAncestry.parentPID(stat: Array("7 (\(comm)) S \(ppid) 1 2".utf8)) == ppid,
                              "comm \(comm.debugDescription)")
            _ = ControlPeerAncestry.parentPID(stat: rng.bytes(count: rng.below(64)))
        }
    }

    // MARK: - This machine's kernel

    @Test func theSystemAncestryReadsThisProcess() {
        #expect(ControlPeerAncestry.system.lookup(getpid())?.parent == getppid())
        #expect(ControlPeerAncestry.system.isInside(getpid(), ancestor: getppid(), executables: []))
        #expect(!ControlPeerAncestry.system.isInside(getpid(), ancestor: 999_999, executables: []))
    }

    @Test func theSystemCredentialsReadTheConnectedProcess() throws {
        var pair: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, ControlSocketServer.streamSocketType, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }
        let peer = ControlPeerCredentials.system.read(pair[0])
        #expect(peer.pid == getpid())
        #expect(peer.uid == getuid())
        let none = ControlPeerCredentials.system.read(-1)
        #expect(none.pid == nil && none.uid == nil, "a descriptor that is no socket reads nothing")
    }
}

/// The server denies a client whose credentials cannot be read, over a real socket.
@Suite(.serialized) struct ControlUnknownPeerServerTests {
    @Test(arguments: [ControlAccessMode.automation, .cmuxOnly])
    func aClientWithUnreadableCredentialsIsDenied(mode: ControlAccessMode) throws {
        let router = ControlRouter(identity: testIdentity(), executor: RecordingExecutor(), configuration: .loadTolerant)
        router.updateCatalog(sampleCatalog())
        let server = ControlSocketServer(
            configuration: .init(path: temporarySocketPath(), accessMode: mode), router: router,
            accept: { accept($0, nil, nil) },
            peerCredentials: ControlPeerCredentials { _ in .init(pid: nil, uid: nil) }
        )
        try server.start()
        defer { server.stop() }
        let client = try LineClient(path: server.configuration.path)
        #expect(client.send("ping") == ControlAuthorizer.accessDenied)
        #expect(client.readLine() == "")
    }
}
