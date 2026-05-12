import Foundation

/// Thin client for the local Synapse daemon at `/tmp/synapse.sock`.
///
/// Synapse provides hybrid (lex + vector + MRL) recall at ~8 ms over
/// SimSIMD kernels. If the socket is not present (daemon not running)
/// every call is a fast no-op so the search palette gracefully
/// degrades to the SQLite FTS5 path in `SearchIndex`.
///
/// Protocol: line-delimited JSON.
///   write: `{"op":"hybrid","q":"<text>","k":50}\n`
///   read : `{"hits":[{"id":"...","score":0.83,"text":"..."}, …]}\n`
///
/// Wire format kept minimal so a swap to the gRPC/HTTP front does not
/// touch callers.
public actor SynapseBridge {
    public struct Hit: Sendable, Hashable {
        public let id: String
        public let score: Double
        public let text: String
    }

    public static let shared = SynapseBridge(
        socketPath: "/tmp/synapse.sock")

    private let socketPath: String
    private var disabledUntil: Date?

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Hybrid recall. Returns `[]` (never throws) on any connectivity
    /// or decode failure; sets a 60 s back-off so the palette stays
    /// responsive when the daemon is down.
    public func hybrid(_ query: String, k: Int = 50) async -> [Hit] {
        if let until = disabledUntil, until > Date() { return [] }
        guard !query.isEmpty,
              FileManager.default.fileExists(atPath: socketPath) else {
            return []
        }
        do {
            let payload = try JSONSerialization.data(withJSONObject: [
                "op": "hybrid", "q": query, "k": k
            ])
            let reply = try await sendReceive(payload)
            return parse(reply)
        } catch {
            disabledUntil = Date().addingTimeInterval(60)
            return []
        }
    }

    /// Index a chunk for later semantic recall. Fire-and-forget.
    public func put(id: String, text: String) async {
        guard FileManager.default.fileExists(atPath: socketPath) else { return }
        let payload = try? JSONSerialization.data(withJSONObject: [
            "op": "put", "id": id, "text": text
        ])
        guard let payload else { return }
        _ = try? await sendReceive(payload, expectReply: false)
    }

    // MARK: - Wire

    private func sendReceive(_ payload: Data, expectReply: Bool = true) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    cont.resume(throwing: POSIXError(.EBADF)); return
                }
                defer { Darwin.close(fd) }

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                _ = self.socketPath.withCString { cstr in
                    withUnsafeMutablePointer(to: &addr.sun_path) {
                        $0.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                            _ = strncpy(dst, cstr, 103)
                        }
                    }
                }
                let len = socklen_t(MemoryLayout<sockaddr_un>.size)
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, len)
                    }
                }
                guard rc == 0 else {
                    cont.resume(throwing: POSIXError(.ECONNREFUSED)); return
                }

                var framed = payload
                framed.append(0x0A) // newline-delimit
                framed.withUnsafeBytes { buf in
                    _ = Darwin.send(fd, buf.baseAddress, buf.count, 0)
                }
                guard expectReply else {
                    cont.resume(returning: Data()); return
                }
                var out = Data()
                var chunk = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = chunk.withUnsafeMutableBufferPointer {
                        Darwin.recv(fd, $0.baseAddress, $0.count, 0)
                    }
                    if n <= 0 { break }
                    out.append(chunk, count: n)
                    if out.last == 0x0A { break }
                }
                cont.resume(returning: out)
            }
        }
    }

    private func parse(_ data: Data) -> [Hit] {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = obj["hits"] as? [[String: Any]]
        else { return [] }
        return raw.compactMap { h in
            guard
                let id = h["id"] as? String,
                let score = (h["score"] as? Double) ?? (h["score"] as? NSNumber)?.doubleValue,
                let text = h["text"] as? String
            else { return nil }
            return Hit(id: id, score: score, text: text)
        }
    }
}
