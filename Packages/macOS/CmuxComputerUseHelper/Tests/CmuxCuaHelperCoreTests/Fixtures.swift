// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxCuaHelperCore
import Darwin
import Foundation
import Synchronization

let acpmuxHash = Data(repeating: 0xA1, count: 20)
let otherHash = Data(repeating: 0xB2, count: 20)
let daemon = ProcessStamp(pid: 4242, startSeconds: 1_700_000_000, startMicroseconds: 17)
let secret = Data((0..<32).map { UInt8($0) })

func config(daemons: Set<ProcessStamp> = [daemon], requirement: String? = nil) -> AdmissionConfig {
    AdmissionConfig(helperUID: geteuid(), acpmuxCDHashes: [acpmuxHash], acpmuxRequirement: requirement,
                    acpmuxDaemons: daemons, secret: secret)
}

/// A bridge process `acpmux cua-mcp` under agent -> acpmux daemon.
func acpmuxBridge(cdhash: Data? = acpmuxHash, ancestors: [ProcessStamp] = [
    ProcessStamp(pid: 5000, startSeconds: 1_700_000_100, startMicroseconds: 0), daemon,
]) -> PeerFacts {
    PeerFacts(uid: geteuid(), stamp: ProcessStamp(pid: 5001, startSeconds: 1_700_000_200, startMicroseconds: 0),
              signatureValid: true, cdhash: cdhash, satisfiesRequirement: false, ancestors: ancestors)
}

struct FixedInspector: PeerInspecting {
    let peer: PeerFacts?
    func facts(forConnection descriptor: Int32, requirement: String?) -> PeerFacts? { peer }
}

final class FakeTools: ToolInvoking, Sendable {
    let calls = Mutex<[String]>([])
    func listTools() async throws -> Data { Data(#"{"tools":[{"name":"click"}]}"#.utf8) }
    func invoke(name: String, arguments: Data) async throws -> Data {
        calls.withLock { $0.append(name + " " + String(decoding: arguments, as: UTF8.self)) }
        return Data(#"{"content":[{"type":"text","text":"ok"}]}"#.utf8)
    }
}

/// A short private socket directory (sun_path is 104 bytes).
func makeSocketDirectory() -> String {
    let path = "/tmp/cuah-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
    mkdir(path, 0o700)
    return path
}

/// A blocking Unix-socket client for tests.
final class TestClient {
    let descriptor: Int32
    private var buffer = HelperWire.LineBuffer()
    private var pending: [Data] = []

    init?(path: String) {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 { close(descriptor); return nil }
    }

    deinit { close(descriptor) }

    func send(_ text: String) { _ = text.withCString { write(descriptor, $0, strlen($0)) } }

    /// The next line as a JSON object, or nil at EOF/timeout.
    func receive() -> [String: Any]? {
        while pending.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = read(descriptor, &bytes, bytes.count)
            if count <= 0 { return nil }
            pending += buffer.append(Data(bytes[0..<count])) ?? []
        }
        return HelperWire.object(pending.removeFirst())
    }

    /// True when the server closed the connection.
    func atEOF() -> Bool {
        var byte: UInt8 = 0
        return read(descriptor, &byte, 1) == 0
    }
}
