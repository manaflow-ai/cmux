import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

struct AcpmuxServerPeerTests {
    @Test func anotherUsersSocketPeerIsRefusedBeforeItsExecutableOrSignature() throws {
        try withSocketPair { descriptor in
            let peerUID = getuid()
            let anotherUID = peerUID == uid_t.max ? peerUID - 1 : peerUID + 1
            let result = AcpmuxServerPeer.check(
                descriptor: descriptor,
                executable: URL(fileURLWithPath: "/not-the-peer"),
                expectedUID: anotherUID
            )

            #expect(result == .failure(.otherUser(peerUID)))
        }
    }

    /// "acpmux is too belt and suspenders there" (Leo): a same-user peer at this app's acpmux
    /// path is usable with no code-signing requirement (the test runner is not Team-signed).
    @Test func aSameUserPeerAtTheAppsPathIsUsableWithoutASignatureGate() throws {
        try withSocketPair { descriptor in
            let result = AcpmuxServerPeer.check(descriptor: descriptor, executable: try ownExecutable())

            #expect(result == .success(.own))
        }
    }

    @Test func aSameUserPeerAtAnotherPathIsAnotherInstallOnlyWhenTheCallerAllowsIt() throws {
        try withSocketPair { descriptor in
            let other = URL(fileURLWithPath: "/not-the-peer")
            let peerPath = try ownExecutable().path

            #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: other, allowForeign: true) == .success(.foreign))
            #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: other) == .failure(.otherExecutable(peerPath)))
        }
    }

    /// The softlock of 2026-10-29: after an update the previous bundle's daemon runs a deleted
    /// file, so its path cannot be read, and every chat said "Another acpmux service is using
    /// this socket" for minutes. "there's frequently nothing wrong with showing the same session
    /// but in two different places" (Leo): where another install is allowed, it is one.
    @Test func aSameUserPeerWhosePathIsUnknownIsAnotherInstallOnlyWhenTheCallerAllowsIt() {
        let executable = URL(fileURLWithPath: "/App/bin/acpmux")
        let me = getuid()
        let other = me == uid_t.max ? me - 1 : me + 1

        #expect(AcpmuxServerPeer.verdict(uid: me, executablePath: nil, executable: executable,
                                         allowForeign: true, expectedUID: me) == .success(.foreign))
        #expect(AcpmuxServerPeer.verdict(uid: me, executablePath: nil, executable: executable,
                                         allowForeign: false, expectedUID: me) == .failure(.noPeer))
        #expect(AcpmuxServerPeer.verdict(uid: other, executablePath: nil, executable: executable,
                                         allowForeign: true, expectedUID: me) == .failure(.otherUser(other)))
        #expect(AcpmuxServerPeer.verdict(uid: nil, executablePath: nil, executable: executable,
                                         allowForeign: true, expectedUID: me) == .failure(.noPeer))
        #expect(AcpmuxServerPeer.verdict(uid: me, executablePath: "/App/bin/acpmux", executable: executable,
                                         allowForeign: false, expectedUID: me) == .success(.own))
    }

    /// The same daemon's WebSocket: once it passed rules 1 and 2 on the unix socket, its listener
    /// is used though its path cannot be read. A process that did not pass them is still refused.
    @Test func theWebSocketOfAnotherInstallWhosePathIsUnknownIsUsed() {
        let executable = URL(fileURLWithPath: "/App/bin/acpmux")
        let paths: [pid_t: String] = [7: "/App/bin/acpmux", 8: "/elsewhere/acpmux"]
        let path = { (pid: pid_t) in paths[pid] }
        let daemon = Self.process(pid: 9, start: 100, version: 1)
        let process = { (pid: pid_t) in pid == 9 ? daemon : nil }
        let foreign = [pid_t(9): daemon]

        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: foreign, process: process, path: path) == nil)
        #expect(AcpmuxServerPeer.refusal([7, 9], executable: executable, foreign: foreign, process: process, path: path) == nil)
        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: [:], process: process, path: path) == .noPeer)
        #expect(AcpmuxServerPeer.refusal([8], executable: executable, foreign: [:], process: process, path: path)
            == .otherExecutable("/elsewhere/acpmux"))
        #expect(AcpmuxServerPeer.refusal([], executable: executable, foreign: foreign, process: process, path: path) == .noPeer)
    }

    /// Codex review of #27799: a daemon that passed rules 1 and 2 exits and the kernel gives its
    /// pid to another process of this user. That process's listener is not the daemon's: its pid
    /// names another process (another start time and pid version), so its path is checked.
    @Test func aPidReusedByAnotherProcessIsNotAnotherInstallsDaemon() {
        let executable = URL(fileURLWithPath: "/App/bin/acpmux")
        let passed = Self.process(pid: 9, start: 100, version: 1)
        let reused = Self.process(pid: 9, start: 200, version: 2)
        let foreign = [pid_t(9): passed]
        let noPath = { (_: pid_t) -> String? in nil }

        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: foreign,
                                         process: { _ in passed }, path: noPath) == nil)
        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: foreign,
                                         process: { _ in reused }, path: noPath) == .noPeer)
        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: foreign,
                                         process: { _ in reused }, path: { _ in "/elsewhere/listener" })
            == .otherExecutable("/elsewhere/listener"))
        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: foreign,
                                         process: { _ in nil }, path: noPath) == .noPeer)
    }

    /// A process as ``AcpmuxDaemonStop/kernelProcess(pid:)`` reads it: `version` is the
    /// audit token's pid version (`val.7`).
    private static func process(pid: pid_t, start: UInt64, version: UInt32) -> AcpmuxDaemonStop.Daemon {
        var token = audit_token_t()
        token.val.5 = UInt32(bitPattern: pid)
        token.val.7 = version
        return AcpmuxDaemonStop.Daemon(pid: pid, startSeconds: start, startMicroseconds: 0, token: token)
    }

    /// End to end on a real process: a listener whose executable file was deleted while it runs,
    /// as an earlier bundle's daemon after Sparkle replaced the app. Its unix socket peer is
    /// another install's, not "the socket's peer process is unknown".
    @Test(.timeLimit(.minutes(2)))
    func aListenerRunningADeletedFileIsAnotherInstall() async throws {
        let root = URL(fileURLWithPath: "/tmp/asp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("nc")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/nc"), to: copy)
        let socket = root.appendingPathComponent("s.sock").path
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/bin/bash")
        // macOS 27 kills a copied system binary at exec; signed ad hoc, the copy runs
        // (AcpmuxDaemonStopTests' daemon). `exec` keeps the pid.
        listener.arguments = ["-c", #"/usr/bin/codesign -f -s - "$0" 2>/dev/null; exec "$0" -dklU "$1""#, copy.path, socket]
        listener.standardInput = FileHandle.nullDevice
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { kill(listener.processIdentifier, SIGKILL) }
        // wakeup-allow: bounded wait (60 s, codesign and the first exec are slow on a loaded runner) for the bind.
        let deadline = ContinuousClock.now + .seconds(60)
        while AcpmuxDaemonStop.listenerPID(socketPath: socket) != listener.processIdentifier,
              listener.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(AcpmuxDaemonStop.listenerPID(socketPath: socket) == listener.processIdentifier)
        try FileManager.default.removeItem(at: copy)
        // The field case: the running process's path cannot be read at all (not a path to a
        // missing file, which base already took as another install's).
        try #require(AcpmuxVersionHandoff.executablePath(pid: listener.processIdentifier) == nil)

        let descriptor = try AcpmuxServerPeer.connect(socket)
        defer { close(descriptor) }
        let executable = URL(fileURLWithPath: "/App/bin/acpmux")
        #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: executable, allowForeign: true) == .success(.foreign))
        #expect(AcpmuxServerPeer.check(descriptor: descriptor, executable: executable) == .failure(.noPeer))
    }

    /// The peer of a socketpair end is this test process.
    private func withSocketPair(_ body: (Int32) throws -> Void) throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        try body(descriptors[0])
    }

    private func ownExecutable() throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        try #require(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0)
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}
