import Darwin
public import Foundation

/// Defensive async client for PRDashboard's one-request-per-connection Unix socket API.
public struct GHPRSocketClient: GHPRPullRequestFetching, Sendable {
    private static let maximumResponseBytes = 4 * 1024 * 1024
    private static let timeoutSeconds: Int = 2

    public init() {}

    public func pullRequest(
        _ reference: GHPRPullRequestReference,
        socketPath: String
    ) async throws -> GHPRPullRequestContext? {
        try await Task.detached(priority: .utility) {
            try Self.pullRequestSynchronously(reference, socketPath: socketPath)
        }.value
    }

    private static func pullRequestSynchronously(
        _ reference: GHPRPullRequestReference,
        socketPath: String
    ) throws -> GHPRPullRequestContext? {
        let response = try call(
            ["command": "pr", "repository": reference.repository, "number": reference.number],
            socketPath: socketPath
        )
        guard let schemaVersion = int(response["schemaVersion"]),
              schemaVersion == 1 || schemaVersion == 2 else {
            throw GHPRSocketError(
                code: "ghpr_schema",
                message: "unsupported schemaVersion",
                refreshKind: .incompatibleResponse
            )
        }
        guard bool(response["ok"]) == true else {
            if let error = response["error"] as? [String: Any], string(error["code"]) == "not_found" {
                return nil
            }
            let message = (response["error"] as? [String: Any]).flatMap { string($0["message"]) }
                ?? "PRDashboard request failed"
            throw GHPRSocketError(code: "ghpr_failed", message: message, refreshKind: .requestFailed)
        }
        guard let raw = response["pullRequest"] as? [String: Any] else { return nil }
        return context(raw: raw, fallback: reference)
    }

    private static func call(_ request: [String: Any], socketPath: String) throws -> [String: Any] {
        let descriptor = try connect(socketPath: socketPath)
        defer { Darwin.close(descriptor) }

        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        try writeAll(payload, descriptor: descriptor)
        Darwin.shutdown(descriptor, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw GHPRSocketError(code: "ghpr_read", message: "socket read failed", refreshKind: .requestFailed)
            }
            if count == 0 { break }
            responseData.append(buffer, count: count)
            guard responseData.count <= maximumResponseBytes else {
                throw GHPRSocketError(
                    code: "ghpr_response_too_large",
                    message: "response exceeded 4 MiB",
                    refreshKind: .incompatibleResponse
                )
            }
        }
        guard !responseData.isEmpty,
              let response = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw GHPRSocketError(
                code: "ghpr_invalid_response",
                message: "invalid JSON response",
                refreshKind: .incompatibleResponse
            )
        }
        return response
    }

    private static func connect(socketPath: String) throws -> Int32 {
        var socketStat = stat()
        guard stat(socketPath, &socketStat) == 0 else {
            throw GHPRSocketError(code: "ghpr_socket_not_found", message: "socket not found", refreshKind: .socketUnavailable)
        }
        guard (socketStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK), socketStat.st_uid == getuid() else {
            throw GHPRSocketError(
                code: "ghpr_socket_invalid",
                message: "path is not a current-user socket",
                refreshKind: .socketUnavailable
            )
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw GHPRSocketError(code: "ghpr_socket_create", message: "socket creation failed", refreshKind: .requestFailed)
        }
        do {
            try configure(descriptor)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard socketPath.utf8CString.count <= capacity else {
                throw GHPRSocketError(
                    code: "ghpr_socket_path",
                    message: "socket path is too long",
                    refreshKind: .socketUnavailable
                )
            }
            socketPath.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                    let destination = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
                    strncpy(destination, source, capacity - 1)
                }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw GHPRSocketError(code: "ghpr_connect", message: "socket connection failed", refreshKind: .socketUnavailable)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func configure(_ descriptor: Int32) throws {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 else {
            throw GHPRSocketError(code: "ghpr_timeout", message: "socket timeout setup failed", refreshKind: .requestFailed)
        }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw GHPRSocketError(code: "ghpr_write", message: "socket write failed", refreshKind: .requestFailed)
                }
                guard count > 0 else {
                    throw GHPRSocketError(code: "ghpr_write_closed", message: "socket closed during write", refreshKind: .requestFailed)
                }
                offset += count
            }
        }
    }

    private static func context(
        raw: [String: Any],
        fallback: GHPRPullRequestReference
    ) -> GHPRPullRequestContext {
        GHPRPullRequestContext(
            repository: string(raw["repository"]) ?? fallback.repository,
            number: int(raw["number"]) ?? fallback.number,
            title: string(raw["title"]) ?? "",
            author: string(raw["author"]) ?? "unknown",
            url: string(raw["url"]).flatMap(URL.init(string:)),
            state: string(raw["state"]) ?? "UNKNOWN",
            isDraft: bool(raw["isDraft"]) ?? false,
            isPinned: bool(raw["isPinned"]) ?? false,
            hasBaseConflicts: bool(raw["hasBaseConflicts"]) ?? false,
            unresolvedCount: int(raw["unresolvedCount"]) ?? 0,
            ciStatus: string(raw["ciStatus"]),
            checkSuccessCount: int(raw["checkSuccessCount"]) ?? 0,
            checkFailureCount: int(raw["checkFailureCount"]) ?? 0,
            checkPendingCount: int(raw["checkPendingCount"]) ?? 0,
            ciIsRunning: bool(raw["ciIsRunning"]) ?? false,
            approvalCount: int(raw["approvalCount"]) ?? 0,
            changesRequestedCount: int(raw["changesRequestedCount"]),
            myReviewStatus: string(raw["myReviewStatus"]),
            jiraTicket: string(raw["jiraTicket"]),
            updatedAt: string(raw["updatedAt"]) ?? ""
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }
}
