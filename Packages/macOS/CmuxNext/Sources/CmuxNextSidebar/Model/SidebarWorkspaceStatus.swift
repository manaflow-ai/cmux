public import CmuxNextDesign
import Foundation

/// What agents and scripts report on a workspace (`cmux workspace
/// status|log|progress`), as the row's status block draws it: keyed entries,
/// the newest log line and the progress label. The bar itself is the row's
/// `SidebarProgress`. The row draws entries first, then the log line, then
/// the progress bar and its label, like classic's sidebar (#16431).
public nonisolated struct SidebarWorkspaceStatus: Hashable, Sendable {
    /// Entries a row shows before it folds the rest into "N more".
    public static let visibleEntryLimit = 3

    public var entries: [Entry]
    public var log: LogLine?
    /// The reported progress's label (`cmux workspace progress set --label`).
    public var progressLabel: String?

    public init(entries: [Entry] = [], log: LogLine? = nil, progressLabel: String? = nil) {
        self.entries = entries
        self.log = log
        self.progressLabel = progressLabel.flatMap { label in
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    public nonisolated struct Entry: Hashable, Sendable {
        public var key: String
        public var text: String
        /// SF Symbol name, one emoji or a stored image or SVG (drawn from ``image``).
        public var icon: String?
        public var tint: Tint?
        /// The stored image or SVG `icon` names, once read (cx-qno.11.1).
        public var image: SidebarFavicon?

        public init(key: String, text: String, icon: String? = nil, tint: Tint? = nil, image: SidebarFavicon? = nil) {
            self.key = key
            self.text = text
            self.icon = icon
            self.tint = tint
            self.image = image
        }

        /// The text, or the key when the text is blank.
        public var displayText: String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? key : trimmed
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

    public var isEmpty: Bool { entries.isEmpty && log == nil && progressLabel == nil }

    /// One text line of the row's status block, in drawing order.
    public nonisolated enum Line: Hashable, Sendable {
        case entry(Entry)
        /// Entries past `visibleEntryLimit`.
        case more(Int)
        case log(LogLine)
        case progressLabel(String)
    }

    /// The text lines the row draws. The progress bar sits between the log
    /// line and the progress label.
    public var lines: [Line] {
        var lines = entries.prefix(Self.visibleEntryLimit).map(Line.entry)
        if entries.count > Self.visibleEntryLimit { lines.append(.more(entries.count - Self.visibleEntryLimit)) }
        if let log { lines.append(.log(log)) }
        if let progressLabel { lines.append(.progressLabel(progressLabel)) }
        return lines
    }

    /// Every entry, the log line and the progress label, for search and
    /// accessibility (the row itself folds entries past the limit).
    public var searchText: String {
        var parts = entries.map(\.displayText)
        if let log { parts.append(log.text) }
        if let progressLabel { parts.append(progressLabel) }
        return parts.joined(separator: " ")
    }
}
