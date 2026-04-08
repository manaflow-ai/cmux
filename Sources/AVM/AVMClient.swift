import Foundation

/// Lightweight Unix domain socket client for communicating with the AVM daemon (avmd).
///
/// The daemon listens at `~/.hyperspace/avm.sock` and speaks newline-delimited JSON-RPC:
///   Request:  `{"method":"<name>","params":{...}}\n`
///   Response: `{"ok":true,"data":{...}}\n`  or  `{"ok":false,"error":"..."}\n`
final class AVMClient: @unchecked Sendable {

    /// Default socket path for avmd.
    static let defaultSocketPath: String = {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
        return "\(home)/.hyperspace/avm.sock"
    }()

    private let socketPath: String
    private let timeout: TimeInterval

    init(socketPath: String = AVMClient.defaultSocketPath, timeout: TimeInterval = 5) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    // MARK: - Public API

    /// Check whether avmd is reachable.
    func ping() async -> Bool {
        do {
            let resp = try await send(method: "ping")
            return resp.ok
        } catch {
            return false
        }
    }

    /// List all registered agents.
    func listAgents() async throws -> [AVMAgentInfo] {
        let resp = try await send(method: "agent.list")
        guard resp.ok, let data = resp.data else {
            throw AVMError.daemonError(resp.error ?? "unknown error")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        return try JSONDecoder().decode([AVMAgentInfo].self, from: jsonData)
    }

    /// Get status of a specific agent.
    func agentStatus(id: UInt64) async throws -> AVMAgentInfo {
        let resp = try await send(method: "agent.status", params: ["id": id])
        guard resp.ok, let data = resp.data else {
            throw AVMError.daemonError(resp.error ?? "unknown error")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        return try JSONDecoder().decode(AVMAgentInfo.self, from: jsonData)
    }

    /// Register an agent process with avmd.
    func registerAgent(name: String, pid: UInt32) async throws -> UInt64 {
        let resp = try await send(method: "agent.register", params: ["name": name, "pid": pid])
        guard resp.ok, let data = resp.data as? [String: Any],
              let id = data["id"] as? UInt64 ?? (data["id"] as? Int).map({ UInt64($0) }) else {
            throw AVMError.daemonError(resp.error ?? "failed to register agent")
        }
        return id
    }

    /// Deregister an agent.
    func deregisterAgent(id: UInt64) async throws {
        let resp = try await send(method: "agent.deregister", params: ["id": id])
        if !resp.ok {
            throw AVMError.daemonError(resp.error ?? "failed to deregister agent")
        }
    }

    /// Get proxy info (port, env vars).
    func proxyInfo() async throws -> AVMProxyInfo {
        let resp = try await send(method: "proxy.info")
        guard resp.ok, let data = resp.data else {
            throw AVMError.daemonError(resp.error ?? "unknown error")
        }
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        return try JSONDecoder().decode(AVMProxyInfo.self, from: jsonData)
    }

    /// Get pending command approvals.
    func pendingApprovals() async throws -> [[String: Any]] {
        let resp = try await send(method: "command.pending")
        guard resp.ok, let data = resp.data as? [[String: Any]] else {
            return []
        }
        return data
    }

    /// Approve a pending command.
    func approveCommand(approvalId: UInt64) async throws {
        let resp = try await send(method: "command.approve", params: ["approval_id": approvalId])
        if !resp.ok {
            throw AVMError.daemonError(resp.error ?? "failed to approve command")
        }
    }

    /// Deny a pending command.
    func denyCommand(approvalId: UInt64) async throws {
        let resp = try await send(method: "command.deny", params: ["approval_id": approvalId])
        if !resp.ok {
            throw AVMError.daemonError(resp.error ?? "failed to deny command")
        }
    }

    /// Reload avmd policy.
    func reloadPolicy() async throws {
        let resp = try await send(method: "policy.reload")
        if !resp.ok {
            throw AVMError.daemonError(resp.error ?? "failed to reload policy")
        }
    }

    /// Get recent egress log entries.
    func egressLog(count: Int = 50) async throws -> [[String: Any]] {
        let resp = try await send(method: "egress.log", params: ["count": count])
        guard resp.ok, let data = resp.data as? [[String: Any]] else {
            return []
        }
        return data
    }

    // MARK: - Transport

    private func send(method: String, params: [String: Any] = [:]) async throws -> AVMResponse {
        // Check socket exists
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw AVMError.socketNotFound(socketPath)
        }

        let addr = sockaddr_un.make(path: socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AVMError.connectionFailed("socket() failed: \(errno)")
        }
        defer { close(fd) }

        // Set send/receive timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Connect
        var addrCopy = addr
        let connectResult = withUnsafePointer(to: &addrCopy) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw AVMError.connectionFailed("connect() failed: \(errno)")
        }

        // Build request
        var request: [String: Any] = ["method": method]
        if !params.isEmpty {
            request["params"] = params
        }
        let jsonData = try JSONSerialization.data(withJSONObject: request)
        var payload = jsonData
        payload.append(0x0A) // newline

        // Send
        let sent = payload.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == payload.count else {
            throw AVMError.connectionFailed("send() incomplete: \(sent)/\(payload.count)")
        }

        // Receive (read until newline)
        var responseData = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
        }

        guard !responseData.isEmpty else {
            throw AVMError.connectionFailed("empty response from avmd")
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AVMError.invalidResponse
        }
        return AVMResponse(
            ok: json["ok"] as? Bool ?? false,
            data: json["data"],
            error: json["error"] as? String
        )
    }
}

// MARK: - Models

struct AVMResponse {
    let ok: Bool
    let data: Any?
    let error: String?
}

struct AVMAgentInfo: Codable, Sendable {
    let id: UInt64
    let name: String
    let pid: UInt32
    let uptimeSecs: Double
    let cpuSecs: Double?
    let rssBytes: UInt64?

    enum CodingKeys: String, CodingKey {
        case id, name, pid
        case uptimeSecs = "uptime_secs"
        case cpuSecs = "cpu_secs"
        case rssBytes = "rss_bytes"
    }

    /// Formatted uptime string (e.g. "2h 15m", "45s").
    var formattedUptime: String {
        let secs = Int(uptimeSecs)
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m \(secs % 60)s" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }

    /// Formatted RSS (e.g. "128 MB", "1.2 GB").
    var formattedRSS: String {
        guard let bytes = rssBytes else { return "-" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        if bytes < 1024 * 1024 * 1024 { return "\(bytes / (1024 * 1024)) MB" }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }

    /// Formatted CPU seconds.
    var formattedCPU: String {
        guard let cpu = cpuSecs else { return "-" }
        if cpu < 60 { return String(format: "%.1fs", cpu) }
        return String(format: "%.1fm", cpu / 60)
    }
}

struct AVMProxyInfo: Codable, Sendable {
    let port: UInt16?
    let envHttp: String?
    let envHttps: String?

    enum CodingKeys: String, CodingKey {
        case port
        case envHttp = "env_http"
        case envHttps = "env_https"
    }
}

enum AVMError: Error, LocalizedError {
    case socketNotFound(String)
    case connectionFailed(String)
    case daemonError(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .socketNotFound(let path):
            return "AVM daemon not running (socket not found: \(path))"
        case .connectionFailed(let detail):
            return "Failed to connect to AVM daemon: \(detail)"
        case .daemonError(let msg):
            return "AVM daemon error: \(msg)"
        case .invalidResponse:
            return "Invalid response from AVM daemon"
        }
    }
}

// MARK: - sockaddr_un helper

private extension sockaddr_un {
    static func make(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    let count = min(src.count, 104)
                    dst.update(from: src.baseAddress!, count: count)
                }
            }
        }
        return addr
    }
}
