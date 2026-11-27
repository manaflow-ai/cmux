import Foundation

// The requests are generated (bindings.json, family TerminalIO); their responses stay here.

extension WaitForTextRequest {
    public struct Response: Decodable, Sendable {
        public var matched: Bool?
        public var text: String
    }
}

extension ReadScrollbackRequest {
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
}
