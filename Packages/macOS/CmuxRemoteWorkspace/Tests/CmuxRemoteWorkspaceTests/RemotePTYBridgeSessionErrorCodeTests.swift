import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemotePTYBridgeServer error codes")
struct RemotePTYBridgeSessionErrorCodeTests {
    private func bridgeErrorPayload(for message: String) throws -> [String: Any] {
        let rpc = RecordingPTYBridgeRPCClient()
        rpc.attachError = NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
        let server = RemotePTYBridgeServer(
            rpcClient: rpc,
            sessionID: "session-1",
            lifecycleID: "attachment-1",
            attachmentID: "attachment-1",
            command: nil,
            requireExisting: true,
            strings: TestPTYBridgeStrings(),
            onStop: { _ in }
        )
        defer { server.stop() }
        let endpoint = try server.start()
        let fd = try connect(endpoint: endpoint)
        defer { Darwin.close(fd) }

        try writeAll(fd: fd, Data("{\"token\":\"\(endpoint.token)\",\"cols\":80,\"rows\":24}\n".utf8))
        let line = try readLine(fd: fd)
        let payload = try JSONSerialization.jsonObject(with: line, options: []) as? [String: Any]
        return try #require(payload)
    }

    @Test("session-not-found attach failures carry the stable bridge error code")
    func sessionNotFoundCarriesCode() throws {
        let payload = try bridgeErrorPayload(for: "persistent SSH PTY session is not running")

        #expect(payload["type"] as? String == "error")
        #expect(payload["message"] as? String == "test-session-ended")
        #expect(payload["code"] as? String == "pty_session_not_found")
    }

    @Test("generic attach failures omit the bridge error code")
    func genericFailureOmitsCode() throws {
        let payload = try bridgeErrorPayload(for: "some generic failure")

        #expect(payload["type"] as? String == "error")
        #expect(payload["message"] as? String == "test-attach-failed")
        #expect(payload["code"] == nil)
    }

    private func connect(endpoint: RemotePTYBridgeServer.Endpoint) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(endpoint.port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr(endpoint.host))
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let errorCode = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return fd
    }

    private func writeAll(fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            }
        }
    }

    private func readLine(fd: Int32) throws -> Data {
        var data = Data()
        var byte = [UInt8](repeating: 0, count: 1)
        while data.count < 4096 {
            let count = Darwin.read(fd, &byte, 1)
            if count > 0 {
                if byte[0] == 0x0A { return data }
                data.append(byte[0])
            } else if count == 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))
            } else if errno != EINTR {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE))
    }
}
