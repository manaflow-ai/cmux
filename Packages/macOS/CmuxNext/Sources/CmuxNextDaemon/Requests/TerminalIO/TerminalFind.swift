import Foundation

/// `terminal-find`: one page of Cmd-F matches over a PTY surface's whole retained history, newest
/// first (cmux-tui `spec/commands.md`). The daemon matches and pages; a client asks for the next
/// page with the previous `nextBefore` and `epoch`. A daemon without the command answers
/// "unknown variant", which the caller treats as no history search.
public struct TerminalFindRequest: DaemonRequest {
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

    public static let command = "terminal-find"
    public var surface: SurfaceID
    public var query: String
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool
    public var before: UInt64?
    public var epoch: UInt64?

    public init(surface: SurfaceID, query: String, caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false,
                before: UInt64? = nil, epoch: UInt64? = nil) {
        self.surface = surface
        self.query = query
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
        self.before = before
        self.epoch = epoch
    }

    enum CodingKeys: String, CodingKey {
        case surface, query, regex, before, epoch
        case caseSensitive = "case_sensitive"
        case wholeWord = "whole_word"
    }
}
