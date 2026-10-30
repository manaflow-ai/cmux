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

        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: [9], path: path) == nil)
        #expect(AcpmuxServerPeer.refusal([7, 9], executable: executable, foreign: [9], path: path) == nil)
        #expect(AcpmuxServerPeer.refusal([9], executable: executable, foreign: [], path: path) == .noPeer)
        #expect(AcpmuxServerPeer.refusal([8], executable: executable, foreign: [], path: path)
            == .otherExecutable("/elsewhere/acpmux"))
        #expect(AcpmuxServerPeer.refusal([], executable: executable, foreign: [9], path: path) == .noPeer)
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
        // (AcpmuxUnresponsiveWatchTests' hung daemon). `exec` keeps the pid.
        listener.arguments = ["-c", #"/usr/bin/codesign -f -s - "$0" 2>/dev/null; exec "$0" -dklU "$1""#, copy.path, socket]
        listener.standardInput = FileHandle.nullDevice
        listener.standardOutput = FileHandle.nullDevice
        listener.standardError = FileHandle.nullDevice
        try listener.run()
        defer { kill(listener.processIdentifier, SIGKILL) }
        // wakeup-allow: bounded wait (60 s, codesign and the first exec are slow on a loaded runner) for the bind.
        let deadline = ContinuousClock.now + .seconds(60)
        while AcpmuxUnresponsiveWatch.listenerPID(socketPath: socket) != listener.processIdentifier,
              listener.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(AcpmuxUnresponsiveWatch.listenerPID(socketPath: socket) == listener.processIdentifier)
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
