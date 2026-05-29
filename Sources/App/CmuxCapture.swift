import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

enum CmuxUITestCapture {
    static func appendLineIfConfigured(envKey: String, line: String) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        appendLine(line, to: url)
        return true
    }

    static func mutateJSONObjectIfConfigured(
        envKey: String,
        _ update: (inout [String: Any]) -> Void
    ) -> Bool {
        guard let url = configuredURL(for: envKey) else { return false }
        mutateJSONObject(at: url, update)
        return true
    }

    private static func configuredURL(for envKey: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        guard let rawPath = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: rawPath)
    }

    private static func appendLine(_ line: String, to url: URL) {
        ensureParentDirectory(for: url)
        let payload = (line + "\n").data(using: .utf8) ?? Data()

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                if let existing = try? Data(contentsOf: url) {
                    var combined = existing
                    combined.append(payload)
                    try? combined.write(to: url, options: .atomic)
                } else {
                    try? payload.write(to: url, options: .atomic)
                }
            }
            return
        }

        try? payload.write(to: url, options: .atomic)
    }

    private static func mutateJSONObject(
        at url: URL,
        _ update: (inout [String: Any]) -> Void
    ) {
        ensureParentDirectory(for: url)
        var payload: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            payload = object
        }
        update(&payload)
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func ensureParentDirectory(for url: URL) {
        let directory = url.deletingLastPathComponent()
        guard !directory.path.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

enum CmuxRuntimeDebugCapture {
    private struct Configuration {
        let baseURL: URL
        let token: String
        let sessionID: String
    }

    private static let configuration: Configuration? = {
        let env = ProcessInfo.processInfo.environment
        guard let baseURLString = env["CMUX_RUNTIME_DEBUG_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let baseURL = URL(string: baseURLString),
              let token = env["CMUX_RUNTIME_DEBUG_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty,
              let sessionID = env["CMUX_RUNTIME_DEBUG_SESSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }
        return Configuration(baseURL: baseURL, token: token, sessionID: sessionID)
    }()

    private static let lock = NSLock()
    private static var sequence: Int = 0

    static func logIfConfigured(
        hypothesisID: String,
        source: String,
        name: String,
        expected: String? = nil,
        actual: String? = nil,
        data: [String: Any] = [:]
    ) {
        guard let configuration else { return }

        var payload: [String: Any] = [
            "session_id": configuration.sessionID,
            "hypothesis_id": hypothesisID,
            "service": "cmux-macos",
            "source": source,
            "name": name,
            "ts": ISO8601DateFormatter().string(from: Date()),
            "mono_ms": ProcessInfo.processInfo.systemUptime * 1000,
            "seq": nextSequence(),
            "data": data
        ]
        if let expected {
            payload["expected"] = expected
        }
        if let actual {
            payload["actual"] = actual
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let requestBody = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }

        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("api/logs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.token, forHTTPHeaderField: "X-Debug-Token")
        request.httpBody = requestBody

        URLSession.shared.dataTask(with: request).resume()
    }

    private static func nextSequence() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        return sequence
    }
}
