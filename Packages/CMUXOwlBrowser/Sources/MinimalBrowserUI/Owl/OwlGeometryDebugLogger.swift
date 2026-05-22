import AppKit
import Foundation
import QuartzCore

@MainActor
enum OwlGeometryDebugLogger {
    private static let logURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["MINIMAL_BROWSER_GEOMETRY_LOG"],
              !path.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }()

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func record(_ event: String, fields: [String: String] = [:]) {
        guard let logURL else {
            return
        }
        var payload = fields
        payload["event"] = event
        payload["time"] = dateFormatter.string(from: Date())
        payload["uptime"] = String(format: "%.6f", ProcessInfo.processInfo.systemUptime)
        let encoded = payload
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\"\(escape(key))\":\"\(escape(value))\""
            }
            .joined(separator: ",")
        let line = "{\(encoded)}\n"
        guard let data = line.data(using: .utf8) else {
            return
        }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
            _ = try? handle.close()
        } else {
            try? data.write(to: logURL, options: [.atomic])
        }
    }

    static func rect(_ rect: CGRect) -> String {
        String(
            format: "%.3f,%.3f,%.3f,%.3f",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    static func size(_ size: CGSize) -> String {
        String(format: "%.3fx%.3f", size.width, size.height)
    }

    static func bool(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for character in string {
            switch character {
            case "\\":
                result += "\\\\"
            case "\"":
                result += "\\\""
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                result.append(character)
            }
        }
        return result
    }
}
