import Foundation

// The request is generated (bindings.json, family TerminalIO); its response stays here.

extension TerminalFindRequest {
    public struct Response: Decodable, Sendable {
        public struct Position: Decodable, Sendable {
            public var marker: UInt64
            public var column: UInt16
        }

        public struct Match: Decodable, Sendable {
            public var start: Position
            public var end: Position
            public var rowsFromBottom: UInt64
            public var snippet: String
            public var snippetStart: UInt32
            public var snippetLen: UInt32

            enum CodingKeys: String, CodingKey {
                case start, end, snippet
                case rowsFromBottom = "rows_from_bottom"
                case snippetStart = "snippet_start"
                case snippetLen = "snippet_len"
            }

            /// The matched text: `snippetLen` UTF-16 units of the snippet from `snippetStart`.
            public var text: String {
                let slice = snippet.utf16.dropFirst(Int(clamping: snippetStart)).prefix(Int(clamping: snippetLen))
                return String(slice) ?? ""
            }
        }

        public var matches: [Match]
        public var nextBefore: UInt64?
        public var complete: Bool
        public var epoch: UInt64?
        public var restarted: Bool?
        public var cols: UInt16?
        public var invalidPattern: String?

        enum CodingKeys: String, CodingKey {
            case matches, complete, epoch, restarted, cols
            case nextBefore = "next_before"
            case invalidPattern = "invalid_pattern"
        }
    }
}
