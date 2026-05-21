import CryptoKit
import Foundation

struct CMUXSudoAuditRecord: Sendable {
    let requestID: String
    let timestamp: Date
    let workspaceID: UUID?
    let surfaceID: UUID?
    let requesterPID: pid_t?
    let requesterUID: uid_t?
    let command: [String]
    let commandDisplay: String
    let result: String
    let exitCode: Int32?
    let errorCode: String?
    let message: String?

    var jsonObject: [String: Any] {
        [
            "request_id": requestID,
            "timestamp": CMUXSudoAuditLogger.iso8601(timestamp),
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "requester_pid": requesterPID.map { Int($0) } as Any? ?? NSNull(),
            "requester_uid": requesterUID.map { Int($0) } as Any? ?? NSNull(),
            "command": command,
            "command_display": commandDisplay,
            "result": result,
            "exit_code": exitCode.map { Int($0) } as Any? ?? NSNull(),
            "error_code": errorCode as Any? ?? NSNull(),
            "message": message as Any? ?? NSNull(),
        ]
    }
}

enum CMUXSudoAuditLogger {
    static let maxBytes: UInt64 = 10 * 1024 * 1024
    static let maxRotatedFiles = 5
    private static let lock = NSLock()

    static var defaultLogURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("sudo-audit.jsonl", isDirectory: false)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func ensureWritable(logURL: URL = defaultLogURL) throws {
        lock.lock()
        defer { lock.unlock() }
        try prepareLogFile(logURL: logURL)
    }

    @discardableResult
    static func append(_ record: CMUXSudoAuditRecord, logURL: URL = defaultLogURL) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        try prepareLogFile(logURL: logURL)
        let previousHash = previousEntryHash(logURL: logURL)
        try rotateIfNeeded(logURL: logURL)

        var object = record.jsonObject
        object["previous_sha256"] = previousHash as Any? ?? NSNull()
        let entryHash = try sha256Hex(canonicalJSONData(object))
        object["entry_sha256"] = entryHash

        var data = try canonicalJSONData(object)
        data.append(0x0a)

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try setPrivatePermissions(logURL)
        return object
    }

    private static func prepareLogFile(logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPrivateDirectoryPermissions(directory)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try setPrivatePermissions(logURL)
    }

    private static func setPrivateDirectoryPermissions(_ directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func setPrivatePermissions(_ logURL: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
    }

    private static func rotateIfNeeded(logURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value >= maxBytes else { return }

        let oldest = rotatedURL(logURL, index: maxRotatedFiles)
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }
        for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let source = rotatedURL(logURL, index: index)
            let destination = rotatedURL(logURL, index: index + 1)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: destination)
                try setPrivatePermissions(destination)
            }
        }
        let first = rotatedURL(logURL, index: 1)
        if FileManager.default.fileExists(atPath: first.path) {
            try FileManager.default.removeItem(at: first)
        }
        try FileManager.default.moveItem(at: logURL, to: first)
        try setPrivatePermissions(first)
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try setPrivatePermissions(logURL)
    }

    private static func rotatedURL(_ logURL: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(index)")
    }

    private static func previousEntryHash(logURL: URL) -> String? {
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty else { return nil }
        guard let decoded = String(data: data, encoding: .utf8) else { return nil }
        let lines = decoded.split(separator: "\n", omittingEmptySubsequences: true)
        guard let last = lines.last,
              let lineData = String(last).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let hash = object["entry_sha256"] as? String,
              !hash.isEmpty else {
            return nil
        }
        return hash
    }

    private static func canonicalJSONData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
