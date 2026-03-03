// MCPBackend.swift
// Backend for communicating with cmux daemon via direct Unix socket

import Foundation

/// Backend for communicating with cmux daemon via Unix socket v2 RPC.
///
/// Sends JSON requests directly to the cmux socket instead of spawning CLI
/// subprocesses. This eliminates CLI flag incompatibilities and subprocess overhead.
///
/// ## Why POSIX syscalls instead of FileHandle
///
/// On macOS, `FileHandle` (`NSConcreteFileHandle`) is Apple's closed-source
/// Foundation implementation. When wrapping a Unix domain socket fd,
/// `FileHandle.write(_:)` does **not** reliably flush data to the socket —
/// the bytes can remain in an internal buffer, causing the subsequent
/// `readData(ofLength:)` to block forever (the daemon never receives the
/// request so it never sends a response).
///
/// This was confirmed empirically:
/// - `FileHandle.write` + `FileHandle.readData` → **hangs indefinitely**
/// - `Darwin.write` + `Darwin.read` on the same fd → **works correctly**
///
/// Apple's own networking guidance (TN3151) recommends against using
/// `NSFileHandle` for socket I/O. The `eonil/TCPIPSocket.Swift` project
/// also documents this caveat. We therefore use direct POSIX `read`/`write`
/// syscalls with proper EINTR retry and short-write handling, following the
/// pattern recommended by Apple DTS (Quinn "The Eskimo!").
public class MCPBackend {

    // MARK: - Properties

    private let socketPath: String
    private let password: String?
    private let lock = NSLock()
    private var requestId: Int = 0

    /// Raw file descriptor for the connected Unix domain socket.
    /// -1 means not connected. Managed directly via POSIX syscalls
    /// (not wrapped in FileHandle — see class-level doc for rationale).
    private var socketFd: Int32 = -1

    // MARK: - Initialization

    public init(socketPath: String = "/tmp/cmux.sock", password: String? = nil, idFormat: String = "refs") {
        self.socketPath = socketPath
        self.password = password
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection Management

    /// Connect to the cmux Unix socket.
    private func connect() throws {
        disconnect()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MCPError.executionFailed("Failed to create socket: \(String(cString: strerror(errno)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw MCPError.executionFailed("Socket path too long: \(socketPath)")
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        guard result == 0 else {
            Darwin.close(fd)
            throw MCPError.executionFailed("Failed to connect to \(socketPath): \(String(cString: strerror(errno)))")
        }

        socketFd = fd
    }

    /// Disconnect from the socket.
    private func disconnect() {
        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }
    }

    /// Ensure we have a live connection, reconnecting if needed.
    private func ensureConnected() throws {
        if socketFd < 0 {
            try connect()
            // Authenticate if password is set
            if let password = password, !password.isEmpty {
                let _ = try sendRPC(method: "auth.login", params: ["password": password])
            }
        }
    }

    // MARK: - POSIX I/O Helpers

    /// Write all bytes to the socket fd, retrying on EINTR and handling short writes.
    ///
    /// Follows the write-loop pattern recommended by Apple DTS for synchronous
    /// socket I/O — see Apple Developer Forums thread 53192.
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(socketFd, base + offset, remaining)
                if written < 0 {
                    if errno == EINTR { continue } // interrupted by signal, retry
                    throw MCPError.executionFailed("Socket write failed: \(String(cString: strerror(errno)))")
                }
                if written == 0 {
                    throw MCPError.executionFailed("Socket write returned 0 (connection closed)")
                }
                offset += written
                remaining -= written
            }
        }
    }

    /// Read from the socket fd until a newline (`\n`) delimiter is found.
    ///
    /// Returns the data before the newline (newline itself is consumed but not included).
    /// Uses a small stack buffer to minimize allocations for typical JSON responses.
    private func readLine() throws -> Data {
        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        var chunk = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = Darwin.read(socketFd, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR { continue } // interrupted by signal, retry
                disconnect()
                throw MCPError.executionFailed("Socket read failed: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 {
                // EOF — connection closed by daemon
                disconnect()
                if buffer.isEmpty {
                    throw MCPError.executionFailed("Socket connection closed")
                }
                break
            }
            if let nlIndex = chunk[0..<bytesRead].firstIndex(of: newline) {
                buffer.append(contentsOf: chunk[0..<nlIndex])
                break
            } else {
                buffer.append(contentsOf: chunk[0..<bytesRead])
            }
        }

        return buffer
    }

    // MARK: - RPC

    /// Send an RPC request to the cmux socket and return the result.
    ///
    /// The cmux socket v2 protocol uses `{id, method, params}` requests and
    /// `{id, ok, result}` or `{id, ok, error}` responses — NOT JSON-RPC 2.0.
    public func rpc(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        // Try once, reconnect on failure, try again
        do {
            try ensureConnected()
            return try sendRPC(method: method, params: params)
        } catch {
            // Connection may be stale — reconnect and retry once
            disconnect()
            try ensureConnected()
            return try sendRPC(method: method, params: params)
        }
    }

    /// Low-level: send a single RPC request and read the response.
    private func sendRPC(method: String, params: [String: Any]) throws -> [String: Any] {
        guard socketFd >= 0 else {
            throw MCPError.executionFailed("Not connected to socket")
        }

        requestId += 1
        let request: [String: Any] = [
            "id": requestId,
            "method": method,
            "params": params
        ]

        let requestData = try JSONSerialization.data(withJSONObject: request)
        var payload = requestData
        payload.append(contentsOf: "\n".utf8)

        try writeAll(payload)

        // Read response (newline-terminated JSON)
        let responseData = try readLine()

        guard let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPError.executionFailed("Invalid response from socket")
        }

        // cmux socket v2: {ok: bool, result: ..., error: ...}
        guard let ok = response["ok"] as? Bool else {
            throw MCPError.executionFailed("Missing 'ok' field in socket response")
        }

        if !ok {
            let errorInfo = response["error"]
            if let errDict = errorInfo as? [String: Any] {
                let code = errDict["code"] as? String ?? "unknown"
                let message = errDict["message"] as? String ?? "Unknown error"
                throw MCPError.executionFailed("\(code): \(message)")
            } else if let errStr = errorInfo as? String {
                throw MCPError.executionFailed(errStr)
            }
            throw MCPError.executionFailed("Unknown socket error")
        }

        // Return the result dict, or empty dict for simple ok responses
        if let result = response["result"] as? [String: Any] {
            return result
        }
        return [:]
    }

    // MARK: - Convenience

    /// Perform an RPC call and return the result as a JSON string.
    public func rpcJSON(method: String, params: [String: Any] = [:]) throws -> String {
        let result = try rpc(method: method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Perform an RPC call and return a formatted text result for MCP tool output.
    public func rpcForTool(method: String, params: [String: Any] = [:]) throws -> MCPToolCallResult {
        let result = try rpc(method: method, params: params)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return MCPToolCallResult(content: [.text(text)])
    }

    public func ping() throws -> Bool {
        let result = try rpc(method: "system.ping")
        return result["pong"] as? Bool == true
    }
}
