public import CmuxNextDesign
import Foundation

/// What agents and scripts report on a workspace (`cmux workspace
/// status|progress|log`): keyed entries, one progress value, and the newest
/// log line. The row draws entries first, then the log line, then the
/// progress bar and its label, like the old sidebar.
public nonisolated struct SidebarWorkspaceStatus: Hashable, Sendable {
    /// Entries a row shows before it folds the rest into "N more".
    public static let visibleEntryLimit = 3

    public var entries: [Entry]
    public var progress: Progress?
    public var log: LogLine?

    public init(entries: [Entry] = [], progress: Progress? = nil, log: LogLine? = nil) {
        self.entries = entries
        self.progress = progress
        self.log = log
    }

    public nonisolated struct Entry: Hashable, Sendable {
        public var key: String
        public var text: String
        /// SF Symbol name or one emoji.
        public var icon: String?
        public var tint: Tint?

        public init(key: String, text: String, icon: String? = nil, tint: Tint? = nil) {
            self.key = key
            self.text = text
            self.icon = icon
            self.tint = tint
        }

        /// The text, or the key when the text is blank.
        public var displayText: String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? key : trimmed
        }
    }

    /// `value` in 0...1; nil draws an empty track (indeterminate).
    public nonisolated struct Progress: Hashable, Sendable {
        public var value: Double?
        public var label: String?

        public init(value: Double?, label: String? = nil) {
            self.value = value.map { min(max($0, 0), 1) }
            self.label = label
        }
    }

    public nonisolated struct LogLine: Hashable, Sendable {
        public var level: LogLevel
        public var text: String

        public init(level: LogLevel, text: String) {
            self.level = level
            self.text = text
        }
    }

    public nonisolated enum LogLevel: String, Hashable, Sendable {
        case info, progress, success, warning, error

        /// Glyph drawn before the log line.
        public var symbol: String {
            switch self {
            case .info: "circle.fill"
            case .progress: "arrowtriangle.right.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .error: "xmark.circle.fill"
            }
        }
    }

    /// A status color: a palette token, or `#RRGGBB[AA]`.
    public nonisolated enum Tint: Hashable, Sendable {
        case palette(GroupColor)
        /// 0xRRGGBBAA.
        case rgba(UInt32)

        /// Nil for anything the daemon would not store.
        public init?(_ value: String?) {
            guard let value, !value.isEmpty else { return nil }
            if let token = GroupColor(rawValue: value.lowercased()) ?? (value.lowercased() == "gray" ? .grey : nil) {
                self = .palette(token)
                return
            }
            // Hex needs its `#`: `facade` is a valid palette-shaped name.
            guard value.hasPrefix("#") else { return nil }
            let digits = String(value.dropFirst())
            guard digits.count == 6 || digits.count == 8, let raw = UInt32(digits, radix: 16) else { return nil }
            self = .rgba(digits.count == 6 ? raw << 8 | 0xFF : raw)
        }
    }

    public var isEmpty: Bool { entries.isEmpty && progress == nil && log == nil }

    /// One text line of the row's status block, in drawing order.
    public nonisolated enum Line: Hashable, Sendable {
        case entry(Entry)
        /// Entries past `visibleEntryLimit`.
        case more(Int)
        case log(LogLine)
        case progressLabel(String)
    }

    /// The text lines the row draws. The progress bar (`showsProgressBar`)
    /// sits between the log line and the progress label.
    public var lines: [Line] {
        var lines = entries.prefix(Self.visibleEntryLimit).map(Line.entry)
        if entries.count > Self.visibleEntryLimit { lines.append(.more(entries.count - Self.visibleEntryLimit)) }
        if let log { lines.append(.log(log)) }
        if let label = progress?.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            lines.append(.progressLabel(label))
        }
        return lines
    }

    public var showsProgressBar: Bool { progress != nil }

    /// Every entry, the log line and the progress, for search and
    /// accessibility (the row itself folds entries past the limit).
    public var searchText: String {
        var parts = entries.map(\.displayText)
        if let log { parts.append(log.text) }
        if let label = progress?.label { parts.append(label) }
        return parts.joined(separator: " ")
    }
}
