import Darwin
import Foundation
import Testing
@testable import CmuxNextDaemon

/// A daemon connection through a bridge child (`cmux link dial`): spawn
/// failure, a refused dial, the stream, the child's exit mid-stream, and
/// the child always reaped.
@Suite struct DaemonBridgeTests {
    static func shell(_ script: String) -> DaemonBridge {
        DaemonBridge(executable: "/bin/sh", arguments: ["-c", script])
    }

    static func gone(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) != 0 && errno == ESRCH
    }

    @Test func aMissingExecutableFailsToLaunch() {
        #expect(throws: DaemonError.self) {
            _ = try LineTransport(path: "/tmp/unused.sock", bridge: DaemonBridge(executable: "/nonexistent/cmux", arguments: []))
        }
        #expect(throws: DaemonError.self) {
            _ = try LineTransport(path: "/tmp/unused.sock", bridge: DaemonBridge(executable: "cmux", arguments: []))
        }
    }

    @Test func aRefusedDialNamesItsErrorCodeAndLeavesNoChild() {
        let bridge = Self.shell(#"printf '{"ok":false,"error_code":"unknown_host","path_state":"unreachable"}\n' >&2; sleep 30"#)
        do {
            _ = try bridge.open()
            Issue.record("a refused dial opened a stream")
        } catch {
            #expect(error.description.contains("unknown_host"), "\(error.description)")
        }
        #expect(throws: DaemonError.self) { try DaemonBridge.check(Data("garbage".utf8)) }
        #expect(throws: DaemonError.self) { try DaemonBridge.check(Data(#"{"path_state":"direct"}"#.utf8)) }
    }

    @Test func theStreamFlowsAndTheChildsExitEndsIt() throws {
        let bridge = Self.shell(#"printf '{"ok":true,"path_state":"direct"}\n' >&2; read line; printf '%s\n' "$line""#)
        let (fd, child) = try bridge.open()
        defer { Darwin.close(fd) }
        let sent = Array("ping\n".utf8)
        _ = sent.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64)
        var received: [UInt8] = []
        while !received.contains(UInt8(ascii: "\n")) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            received += buffer.prefix(count)
        }
        #expect(String(decoding: received, as: UTF8.self) == "ping\n")
        // The child exits after one line: the stream ends.
        #expect(Darwin.read(fd, &buffer, buffer.count) == 0)
        child.terminate()
        #expect(Self.gone(child.pid))
    }

    @Test func closingTheConnectionKillsAndReapsTheChild() throws {
        let transport = try LineTransport(path: "/tmp/unused.sock", bridge: Self.shell(#"printf '{"ok":true}\n' >&2; sleep 30"#))
        let pid = try #require(transport.bridgePIDForTesting)
        #expect(!Self.gone(pid))
        transport.close()
        #expect(Self.gone(pid))
    }
}
