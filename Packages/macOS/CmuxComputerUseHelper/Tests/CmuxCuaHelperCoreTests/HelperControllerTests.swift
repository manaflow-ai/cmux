// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Synchronization
import Testing

/// A host-side view of the control pipe.
final class ControlPipe {
    let hostWrite: Int32
    let hostRead: Int32
    let helperRead: Int32
    let helperWrite: Int32
    private var buffer = HelperWire.LineBuffer()
    private var pending: [Data] = []

    init() {
        var toHelper: [Int32] = [-1, -1]
        var toHost: [Int32] = [-1, -1]
        pipe(&toHelper)
        pipe(&toHost)
        helperRead = toHelper[0]; hostWrite = toHelper[1]
        hostRead = toHost[0]; helperWrite = toHost[1]
    }

    func send(_ text: String) { _ = text.withCString { write(hostWrite, $0, strlen($0)) } }

    func receive() -> [String: Any]? {
        var poller = pollfd(fd: hostRead, events: Int16(POLLIN), revents: 0)
        while pending.isEmpty {
            guard poll(&poller, 1, 5000) == 1 else { return nil }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(hostRead, &bytes, bytes.count)
            if count <= 0 { return nil }
            pending += buffer.append(Data(bytes[0..<count])) ?? []
        }
        return HelperWire.object(pending.removeFirst())
    }
}

@Suite(.serialized) struct HelperControllerTests {
    @Test func configureStartsTheSocketAndRegisterAddsTheDaemon() throws {
        let pipe = ControlPipe()
        let exited = Mutex<Int32?>(nil)
        let controller = HelperController(input: pipe.helperRead, output: pipe.helperWrite, tools: FakeTools(),
                                          inspector: FixedInspector(peer: nil), onExit: { code in exited.withLock { $0 = code } })
        controller.start()
        let path = makeSocketDirectory() + "/h.sock"
        pipe.send(#"{"type":"configure","socket":"\#(path)","secret":"\#(HelperWire.hex(secret))","acpmux_cdhashes":["\#(HelperWire.hex(acpmuxHash))"]}"# + "\n")
        let ready = try #require(pipe.receive())
        #expect(ready["type"] as? String == "ready")
        #expect(ready["socket"] as? String == path)
        #expect(ready["pid"] as? Int == Int(getpid()))
        #expect(access(path, F_OK) == 0)
        pipe.send(#"{"type":"register_acpmux","pid":4242,"start_sec":1700000000,"start_usec":17}"# + "\n")
        #expect(pipe.receive()?["ok"] as? Bool == true)
        #expect(controller.admission.current?.acpmuxDaemons == [daemon])
        #expect(controller.admission.current?.acpmuxCDHashes == [acpmuxHash])
        close(pipe.hostWrite)
        try waitUntil { exited.withLock { $0 } == 0 }
        #expect(access(path, F_OK) != 0)
    }

    @Test func callRunsATool() throws {
        let pipe = ControlPipe()
        let tools = FakeTools()
        let controller = HelperController(input: pipe.helperRead, output: pipe.helperWrite, tools: tools,
                                          inspector: FixedInspector(peer: nil), onExit: { _ in })
        controller.start()
        pipe.send(#"{"type":"call","id":3,"name":"check_permissions","arguments":{"prompt":false}}"# + "\n")
        let result = try #require(pipe.receive())
        #expect(result["type"] as? String == "result")
        #expect(result["id"] as? Int == 3)
        #expect(result["ok"] as? Bool == true)
        close(pipe.hostWrite)
    }

    @Test func shortSecretAndRelativeSocketAreRejected() throws {
        let pipe = ControlPipe()
        let controller = HelperController(input: pipe.helperRead, output: pipe.helperWrite, tools: FakeTools(),
                                          inspector: FixedInspector(peer: nil), onExit: { _ in })
        controller.start()
        pipe.send(#"{"type":"configure","socket":"rel.sock","secret":"\#(HelperWire.hex(secret))"}"# + "\n")
        #expect(pipe.receive()?["type"] as? String == "error")
        pipe.send(#"{"type":"configure","socket":"/tmp/x.sock","secret":"00ff"}"# + "\n")
        #expect(pipe.receive()?["type"] as? String == "error")
        #expect(controller.admission.current == nil)
        close(pipe.hostWrite)
    }

    /// Required test 4, process level: the real helper executable exits when
    /// its stdin (the host's liveness pipe) closes, and removes its socket.
    @Test func helperProcessExitsOnStdinEOF() throws {
        let executable = try #require(helperExecutable())
        let pipe = ControlPipe()
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pipe.helperRead, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipe.helperWrite, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.hostWrite)
        posix_spawn_file_actions_addclose(&actions, pipe.hostRead)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), nil]
        defer { argv.forEach { free($0) } }
        #expect(posix_spawn(&pid, executable, &actions, nil, argv, environ) == 0)
        close(pipe.helperRead)
        close(pipe.helperWrite)
        let path = makeSocketDirectory() + "/h.sock"
        pipe.send(#"{"type":"configure","socket":"\#(path)","secret":"\#(HelperWire.hex(secret))","acpmux_cdhashes":[]}"# + "\n")
        let ready = try #require(pipe.receive())
        #expect(ready["type"] as? String == "ready")
        #expect(ready["pid"] as? Int == Int(pid))
        close(pipe.hostWrite)
        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(5)
        var reaped: pid_t = 0
        while reaped == 0, Date() < deadline {
            reaped = waitpid(pid, &status, WNOHANG)
            if reaped == 0 { usleep(20_000) }
        }
        if reaped == 0 { kill(pid, SIGKILL); waitpid(pid, &status, 0) }
        #expect(reaped == pid)
        #expect(status == 0)
        #expect(access(path, F_OK) != 0)
    }
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw ToolError("timed out") }
        usleep(10_000)
    }
}

/// The built `cmux-cua-helper` beside this test bundle.
func helperExecutable() -> String? {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var candidates = [package.appending(path: ".build/debug/cmux-cua-helper").path]
    if let enumerator = FileManager.default.enumerator(atPath: package.appending(path: ".build").path) {
        while let item = enumerator.nextObject() as? String {
            if item.hasSuffix("/debug/cmux-cua-helper") { candidates.append(package.appending(path: ".build/" + item).path) }
            if enumerator.level > 3 { enumerator.skipDescendants() }
        }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
