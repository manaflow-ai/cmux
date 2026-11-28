public import Foundation

/// Writes a profile's tree in the Netscape bookmark format other browsers
/// import: the Bookmarks Bar as a folder marked
/// `PERSONAL_TOOLBAR_FOLDER="true"`, then Other Bookmarks' children at the
/// top level. `NetscapeBookmarkReader.read` returns the same tree.
public nonisolated enum NetscapeBookmarkWriter {
    public static func write(_ tree: BookmarkTree, barTitle: String) -> String {
        var lines = [
            "<!DOCTYPE NETSCAPE-Bookmark-file-1>",
            "<!-- This is an automatically generated file.",
            "     It will be read and overwritten.",
            "     DO NOT EDIT! -->",
            "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
            "<TITLE>Bookmarks</TITLE>",
            "<H1>Bookmarks</H1>",
            "<DL><p>",
        ]
        lines.append("    <DT><H3 PERSONAL_TOOLBAR_FOLDER=\"true\">\(escape(barTitle))</H3>")
        lines.append("    <DL><p>")
        append(tree, parent: BookmarkRoot.bar.rawValue, depth: 2, to: &lines)
        lines.append("    </DL><p>")
        append(tree, parent: BookmarkRoot.other.rawValue, depth: 1, to: &lines)
        lines.append("</DL><p>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func append(_ tree: BookmarkTree, parent: String, depth: Int, to lines: inout [String]) {
        let indent = String(repeating: "    ", count: depth)
        for node in tree.children(of: parent) {
            let added = " ADD_DATE=\"\(Int64(node.created.timeIntervalSince1970))\""
            switch node.kind {
            case .folder:
                lines.append("\(indent)<DT><H3\(added)>\(escape(node.title))</H3>")
                lines.append("\(indent)<DL><p>")
                append(tree, parent: node.id, depth: depth + 1, to: &lines)
                lines.append("\(indent)</DL><p>")
            case .url:
                guard let url = node.url else { continue }
                lines.append("\(indent)<DT><A HREF=\"\(escape(url.absoluteString))\"\(added)>\(escape(node.title))</A>")
            }
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\n", "\r": result += " "
            default: result.append(character)
            }
        }
        return result
    }
}
