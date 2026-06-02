import Foundation
import os

nonisolated private let cmuxBrowserMCPLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.manaflow.cmux",
    category: "BrowserMCP"
)

extension CMUXBrowserMCPServer {
    func toolJSON(_ payload: [String: Any]) -> [String: Any] {
        toolText(compactJSONString(cli.formatIDs(payload, mode: .refs)))
    }

    func toolText(_ text: String, isError: Bool = false) -> [String: Any] {
        var response: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text,
                ],
            ],
        ]
        if isError {
            response["isError"] = true
        }
        return response
    }

    func writeResponse(id: Any?, result: Any) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    func writeError(id: Any?, code: Int, message: String) {
        writeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    func writeJSON(_ object: Any) {
        let line = compactJSONString(object) + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    func logDiagnostic(_ message: String) {
        cmuxBrowserMCPLogger.error("\(message, privacy: .public)")
    }

    func compactJSONString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
              let output = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return output
    }

    func sanitizedErrorMessage(_ error: Error) -> String {
        let raw: String
        if let cliError = error as? CLIError {
            raw = cliError.message
        } else {
            raw = String(describing: error)
        }
        let redacted = redactSensitiveDetails(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if redacted.isEmpty {
            return String(localized: "cli.browserMCP.error.generic", defaultValue: "cmux browser MCP tool failed")
        }
        return redacted
    }

    func redactSensitiveDetails(_ message: String) -> String {
        var output = message
        let redactions: [(String?, String)] = [
            (socketPath, "<cmux socket>"),
            (ProcessInfo.processInfo.environment["CMUX_SOCKET_PATH"], "<cmux socket>"),
            (ProcessInfo.processInfo.environment["CMUX_SOCKET"], "<cmux socket>"),
            (explicitPassword, "<redacted>"),
            (FileManager.default.homeDirectoryForCurrentUser.path, "~"),
        ]
        for (rawSecret, replacement) in redactions {
            guard let secret = rawSecret,
                  !secret.isEmpty else { continue }
            output = output.replacingOccurrences(of: secret, with: replacement)
        }
        return output
    }

    static func versionString() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let shortVersion,
           !shortVersion.isEmpty,
           !shortVersion.contains("$("),
           let build,
           !build.isEmpty,
           !build.contains("$(") {
            return "\(shortVersion)+\(build)"
        }
        return "unknown"
    }
}
