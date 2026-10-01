import Foundation

/// `read-screen`: plain-text viewport of a PTY surface.
public struct ReadScreenRequest: DaemonRequest {
    public struct Response: Decodable, Sendable { public var text: String }
    public static let command = "read-screen"
    public var surface: SurfaceID

    public init(surface: SurfaceID) {
        self.surface = surface
    }
}

/// `read-scrollback`: one page of retained history rows (styled runs),
/// flattened to text lines by `text`. `count` 0 asks for `total` only.
public struct ReadScrollbackRequest: DaemonRequest {
    public struct Response: Decodable, Sendable {
        public struct Row: Decodable, Sendable {
            public struct Run: Decodable, Sendable { public var text: String }
            public var runs: [Run]
        }
        public var rows: [Row]
        public var start: UInt32
        public var total: UInt32

        /// One line per row, trailing blanks dropped.
        public var lines: [String] {
            rows.map { row in
                let line = row.runs.map(\.text).joined()
                return String(line.reversed().drop(while: { $0 == " " }).reversed())
            }
        }

        public var text: String { lines.joined(separator: "\n") }
    }
    public static let command = "read-scrollback"
    public var surface: SurfaceID
    public var start: UInt32
    public var count: UInt32

    public init(surface: SurfaceID, start: UInt32, count: UInt32) {
        self.surface = surface
        self.start = start
        self.count = count
    }
}
