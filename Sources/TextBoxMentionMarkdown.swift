import Foundation

struct TextBoxMentionMarkdown {
    static func link(label: String, path: String) -> String {
        let escapedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(escapedLabel)](\(markdownTarget(for: path)))"
    }

    private static func markdownTarget(for path: String) -> String {
        if path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
            path.contains("(") ||
            path.contains(")") ||
            path.contains("<") ||
            path.contains(">") {
            let escapedPath = path
                .replacingOccurrences(of: "<", with: "%3C")
                .replacingOccurrences(of: ">", with: "%3E")
            return "<\(escapedPath)>"
        }
        return path.replacingOccurrences(of: ")", with: "%29")
    }
}
