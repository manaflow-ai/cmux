import CmuxRemoteSession
import Foundation

/// Parses a raw tmux window-layout string into a ``RemoteTmuxLayoutNode`` tree.
///
/// The format (from `#{window_layout}` / `%layout-change`) is a 4-hex-char
/// checksum, a comma, then a recursive node:
/// ```
/// f92f,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}
/// ```
/// where each node is `WxH,X,Y` followed by one of:
/// - `,<paneId>` — a leaf pane,
/// - `{ … }` — a left-right (horizontal) split of comma-separated child nodes,
/// - `[ … ]` — a top-bottom (vertical) split of comma-separated child nodes.
enum RemoteTmuxRawLayoutParser {
    /// Parses a window-layout string (with or without the leading checksum).
    ///
    /// - Returns: the root layout node, or `nil` if the string is malformed.
    static func parse(_ raw: String) -> RemoteTmuxLayoutNode? {
        // Normalize first: the strict `cursor == chars.count` completion check below
        // would otherwise reject an otherwise-valid layout that carries a trailing
        // newline/space.
        var chars = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // Strip a leading 4-hex-char checksum followed by a comma, if present.
        if chars.count > 5,
           chars[4] == ",",
           chars[0..<4].allSatisfy(\.isHexDigit) {
            chars.removeFirst(5)
        }
        var cursor = 0
        guard let node = parseNode(chars, &cursor), cursor == chars.count else { return nil }
        let paneIDs = node.paneIDsInOrder
        guard Set(paneIDs).count == paneIDs.count else { return nil }
        return node
    }

    private static func parseNode(_ chars: [Character], _ cursor: inout Int) -> RemoteTmuxLayoutNode? {
        guard let width = parseInt(chars, &cursor), consume(chars, &cursor, "x"),
              let height = parseInt(chars, &cursor), consume(chars, &cursor, ","),
              let x = parseInt(chars, &cursor), consume(chars, &cursor, ","),
              let y = parseInt(chars, &cursor) else { return nil }

        guard cursor < chars.count else { return nil }
        let content: RemoteTmuxLayoutNode.Content
        switch chars[cursor] {
        case ",":
            cursor += 1
            guard let paneId = parseInt(chars, &cursor) else { return nil }
            content = .pane(paneId)
        case "{":
            guard let children = parseChildren(chars, &cursor, open: "{", close: "}") else { return nil }
            content = .horizontal(children)
        case "[":
            guard let children = parseChildren(chars, &cursor, open: "[", close: "]") else { return nil }
            content = .vertical(children)
        default:
            return nil
        }
        return RemoteTmuxLayoutNode(width: width, height: height, x: x, y: y, content: content)
    }

    private static func parseChildren(
        _ chars: [Character], _ cursor: inout Int, open: Character, close: Character
    ) -> [RemoteTmuxLayoutNode]? {
        guard consume(chars, &cursor, open) else { return nil }
        var children: [RemoteTmuxLayoutNode] = []
        while true {
            guard let child = parseNode(chars, &cursor) else { return nil }
            children.append(child)
            guard cursor < chars.count else { return nil }
            if chars[cursor] == close { cursor += 1; break }
            if chars[cursor] == "," { cursor += 1; continue }
            return nil
        }
        return children.count >= 2 ? children : nil
    }

    private static func parseInt(_ chars: [Character], _ cursor: inout Int) -> Int? {
        let start = cursor
        while cursor < chars.count, chars[cursor].isNumber { cursor += 1 }
        guard cursor > start else { return nil }
        return Int(String(chars[start..<cursor]))
    }

    private static func consume(_ chars: [Character], _ cursor: inout Int, _ expected: Character) -> Bool {
        guard cursor < chars.count, chars[cursor] == expected else { return false }
        cursor += 1
        return true
    }
}
