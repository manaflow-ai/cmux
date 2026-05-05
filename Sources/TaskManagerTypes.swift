import Foundation
import SwiftUI

struct CmuxTaskManagerRow: Identifiable {
    enum Kind: String {
        case window
        case workspace
        case tag
        case pane
        case terminalSurface
        case browserSurface
        case webview
        case process

        var systemImage: String {
            switch self {
            case .window: return "macwindow"
            case .workspace: return "rectangle.stack"
            case .tag: return "tag"
            case .pane: return "square.split.2x1"
            case .terminalSurface: return "terminal"
            case .browserSurface: return "globe"
            case .webview: return "network"
            case .process: return "gearshape"
            }
        }

        var tint: Color {
            switch self {
            case .window: return .secondary
            case .workspace: return .accentColor
            case .tag: return .orange
            case .pane: return .secondary
            case .terminalSurface: return .green
            case .browserSurface: return .blue
            case .webview: return .purple
            case .process: return .secondary
            }
        }
    }

    let id: String
    let kind: Kind
    let level: Int
    let title: String
    let detail: String
    let resources: CmuxTaskManagerResources
    let isDimmed: Bool
}

struct CmuxTaskManagerResources {
    static let zero = CmuxTaskManagerResources(cpuPercent: 0, residentBytes: 0, processCount: 0)

    let cpuPercent: Double
    let residentBytes: Int64
    let processCount: Int

    init(cpuPercent: Double, residentBytes: Int64, processCount: Int) {
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.processCount = processCount
    }

    init(_ payload: [String: Any]) {
        self.cpuPercent = Self.double(payload["cpu_percent"])
        self.residentBytes = Self.int64(payload["resident_bytes"])
        self.processCount = Self.int(payload["process_count"]) ?? 0
    }

    private static func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String,
           let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private static func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        if let value = raw as? String,
           let parsed = Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        return 0
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

enum CmuxTaskManagerFormat {
    private static let isoFormatter = ISO8601DateFormatter()
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    static func cpu(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, value))
    }

    static func bytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes))
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(value)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", value, units[unitIndex])
    }

    static func iso8601Date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoFormatter.date(from: raw)
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}
