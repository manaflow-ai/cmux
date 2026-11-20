import Foundation
import os
import Testing
@testable import CmuxNextDaemon

/// SWITCH FRAMES SF-5 C (lead 17:4xZ): the busy-terminal bench was too noisy to show that the app's hidden terminals
/// get batched output, so this proves it on the wire. A real ``TerminalAttachment`` against a stub daemon whose
/// identify lists `attach-visibility-v1`: hiding the view sends `set-attach-visibility {visible: false}` after the
/// view stops counting toward the grid, and showing it sends `{visible: true}` before it counts again. Against a daemon
/// without the capability, nothing new goes out. (The daemon side, one output event per second for a hidden viewer,
/// is `a_hidden_snapshot_viewer_gets_output_once_a_second_and_at_once_when_shown` in cmux-tui-core.)
@Suite(.timeLimit(.minutes(1))) struct TerminalAttachVisibilityWireTests {
    @Test func hidingAndShowingTheViewTellTheDaemonToBatchAndStop() async throws {
        let daemon = try VisibilityStubDaemon(capabilities: ["shared-sizing-v1", "attach-visibility-v1"])
        defer { daemon.stop() }
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: daemon.path), target: .init(surface: SurfaceID(rawValue: 7)),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        defer { attachment.detachNow() }
        attachment.sendHidden(true)
        attachment.sendHidden(false)
        let seen = try await daemon.waitFor(count: 4)
        #expect(seen == ["set-size-counts", "set-attach-visibility false", "set-attach-visibility true", "set-size-counts"],
                "\(seen)")
    }

    @Test func aDaemonWithoutTheCapabilityGetsOnlyTheSizingCommands() async throws {
        let daemon = try VisibilityStubDaemon(capabilities: ["shared-sizing-v1"])
        defer { daemon.stop() }
        let attachment = try await TerminalAttachment.attach(
            endpoint: DaemonEndpoint(socketPath: daemon.path), target: .init(surface: SurfaceID(rawValue: 7)),
            size: CellSize(cols: 80, rows: 24), claimGeometry: false)
        defer { attachment.detachNow() }
        attachment.sendHidden(true)
        attachment.sendHidden(false)
        let seen = try await daemon.waitFor(count: 2)
        try await Task.sleep(for: .milliseconds(200)) // test: a third command would have arrived by now
        #expect(daemon.commands == ["set-size-counts", "set-size-counts"], "\(daemon.commands) (first two: \(seen))")
    }
}

/// Answers identify with `capabilities`, every request `ok`, attach-surface with a lease, and records the sizing and
/// visibility commands it gets, in order.
private nonisolated final class VisibilityStubDaemon: @unchecked Sendable {  // the fd is written once in init and closed once in stop
    let path: String
    private let descriptor: Int32
    private let capabilities: [String]
    private let seen = OSAllocatedUnfairLock<[String]>(initialState: [])
    var commands: [String] { seen.withLock { $0 } }

    init(capabilities: [String]) throws {
        self.capabilities = capabilities
        path = FileManager.default.temporaryDirectory.appendingPathComponent("vis-\(UUID().uuidString.prefix(8)).sock").path
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = path
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
    }

    /// The first `count` recorded commands, waiting up to 5 s for them.
    func waitFor(count: Int) async throws -> [String] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let now = commands
            if now.count >= count { return Array(now.prefix(count)) }
            try await Task.sleep(for: .milliseconds(10)) // test: the attachment's commands are fire-and-forget
        }
        return commands
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        let reply = { (object: [String: Any]) in
            guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
            line.append(0x0A)
            _ = line.withUnsafeBytes { send(client, $0.baseAddress, line.count, 0) }
        }
        let identity: [String: Any] = ["app": "cmux-tui", "protocol": 12, "generation": "boot-1", "capabilities": capabilities]
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer += Data(chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                let cmd = object["cmd"] as? String ?? ""
                switch cmd {
                case "set-size-counts", "release-attached-view-size":
                    seen.withLock { $0.append(cmd) }
                case "set-attach-visibility":
                    let entry = "\(cmd) \((object["visible"] as? Bool).map(String.init) ?? "?")"
                    seen.withLock { $0.append(entry) }
                default:
                    break
                }
                guard let id = object["id"] else { continue }
                let data: [String: Any] = switch cmd {
                case "identify": identity
                case "attach-surface": ["lease": "l1"]
                default: [:]
                }
                reply(["id": id, "ok": true, "data": data])
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }
}
