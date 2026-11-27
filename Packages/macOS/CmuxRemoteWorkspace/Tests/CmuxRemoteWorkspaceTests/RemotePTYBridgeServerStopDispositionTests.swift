import Darwin
import Foundation
import Testing
@testable import CmuxRemoteWorkspace

@Suite("RemotePTYBridgeServer stop disposition")
struct RemotePTYBridgeServerStopDispositionTests {
    @Test("an endpoint stopped before accept reports unused")
    func unusedEndpointReportsUnused() throws {
        let unused = DispatchSemaphore(value: 0)
        let accepted = DispatchSemaphore(value: 0)
        let server = makeServer { disposition in
            (disposition == .unused ? unused : accepted).signal()
        }
        _ = try server.start()

        server.stop()

        #expect(unused.wait(timeout: .now() + 2) == .success)
        #expect(accepted.wait(timeout: .now()) == .timedOut)
    }

    @Test("an endpoint with an authenticated client reports accepted")
    func authenticatedEndpointReportsAccepted() throws {
        let unused = DispatchSemaphore(value: 0)
        let accepted = DispatchSemaphore(value: 0)
        let server = makeServer { disposition in
            (disposition == .unused ? unused : accepted).signal()
        }
        let endpoint = try server.start()
        let fd = try connect(endpoint)
        defer { Darwin.close(fd) }
        try writeAll(fd, Data("{\"token\":\"\(endpoint.token)\",\"cols\":80,\"rows\":24}\n".utf8))
        _ = try readLine(fd)

        server.stop()

        #expect(accepted.wait(timeout: .now() + 2) == .success)
        #expect(unused.wait(timeout: .now()) == .timedOut)
    }

    @Test("an invalid-token client leaves the endpoint unused")
    func invalidTokenReportsUnused() throws {
        let unused = DispatchSemaphore(value: 0)
        let accepted = DispatchSemaphore(value: 0)
        let server = makeServer { disposition in
            (disposition == .unused ? unused : accepted).signal()
        }
        let endpoint = try server.start()
        let fd = try connect(endpoint)
        defer { Darwin.close(fd) }

        try writeAll(fd, Data("{\"token\":\"invalid\",\"cols\":80,\"rows\":24}\n".utf8))

        #expect(unused.wait(timeout: .now() + 2) == .success)
        #expect(accepted.wait(timeout: .now()) == .timedOut)
    }

    private func makeServer(
        onStop: @escaping (RemotePTYBridgeStopDisposition) -> Void
    ) -> RemotePTYBridgeServer {
        RemotePTYBridgeServer(
            rpcClient: RecordingPTYBridgeRPCClient(),
            sessionID: "session",
            lifecycleID: "lifecycle",
            attachmentID: "attachment",
            command: nil,
            requireExisting: false,
            strings: TestPTYBridgeStrings(),
            onStop: onStop
        )
    }

    private func connect(_ endpoint: RemotePTYBridgeServer.Endpoint) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(endpoint.port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(endpoint.host))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
        }
    }

    private func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while result.count < 4096 {
            let count = Darwin.read(fd, &byte, 1)
            if count > 0, byte == 0x0A { return result }
            if count > 0 { result.append(byte); continue }
            if count < 0, errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EMSGSIZE))
    }
}
