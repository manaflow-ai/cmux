import Foundation
import Testing
@testable import CmuxNextDaemon

@Suite(.serialized)
struct AgentSessionAttachClientCloudRepositoryTests {
    @Test func cloudRepositoryUsesTheAttachFrameWithSurfaceAndParams() async throws {
        let daemon = try CloudRepositoryDaemon()
        defer { daemon.stop() }
        let client = AgentSessionAttachClient(surface: 42, requestTimeout: .seconds(2)) {
            DaemonEndpoint(socketPath: daemon.path)
        }
        let data = try await client.cloudRepository(
            method: "cloud.repo.list",
            params: ["session": "chat-1", "query": "cmux-platform"],
            timeout: .seconds(2)
        )
        await client.close()
        let value = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(value["repos"] as? [Any] != nil)
        let request = try #require(daemon.request(where: { $0["cmd"] as? String == "cloud.repo.list" }))
        #expect(request["surface"] as? Int == 42)
        #expect(request["session"] as? String == "chat-1")
        #expect(request["query"] as? String == "cmux-platform")
    }
}

private final class CloudRepositoryDaemon: @unchecked Sendable {
    let path: String
    private let descriptor: Int32
    private let lock = NSLock()
    private var requests: [[String: Any]] = []

    init() throws {
        path = "/tmp/cr-\(UUID().uuidString).sock"
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        path.withCString { raw in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                let source = UnsafeRawBufferPointer(start: raw, count: min(path.utf8.count, bytes.count - 1))
                bytes.copyBytes(from: source)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 2) == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        Thread.detachNewThread { [self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(client, &chunk, chunk.count, 0)
            guard count > 0 else { return }
            buffer.append(contentsOf: chunk.prefix(count))
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = object["id"] else { continue }
                lock.lock(); requests.append(object); lock.unlock()
                let cmd = object["cmd"] as? String
                let data: [String: Any]
                if cmd == "identify" {
                    data = ["app": "cmux-tui", "version": "0", "protocol": 12,
                            "capabilities": ["agent-session-attach-v1"], "session": "test",
                            "pid": 0, "generation": "boot-1"]
                } else if cmd == "cloud.repo.list" {
                    data = ["repos": [[String: Any]()]]
                } else {
                    data = [:]
                }
                guard let encoded = try? JSONSerialization.data(withJSONObject: ["id": id, "ok": true, "data": data]) else { continue }
                var reply = encoded; reply.append(0x0A)
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, reply.count, 0) }
            }
        }
    }

    func stop() {
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }

    func request(where predicate: ([String: Any]) -> Bool) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return requests.first(where: predicate)
    }
}
