import CmuxChief
import CmuxHomeCore
import Foundation

/// One-line conversation list previews for the Chief: Markdown flattened to
/// what the transcript shows, and a waiting approval said as the transcript's
/// status ("Waiting for you") instead of the card's raw prompt ("Run `…`?").
enum ChiefPreviewText {
    /// `markdown` without its markers: inline code and fences, bold, italic and
    /// strike markers, links and images (their text kept), heading hashes,
    /// quote markers and bullets; lines joined with spaces, runs of white space
    /// collapsed. Pure: no catalog, no store.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { continue }
            line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^(>\s?)+"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: #"^[-*+]\s+(\[[ xX]\]\s+)?"#, with: "", options: .regularExpression)
            if !line.isEmpty { lines.append(line) }
        }
        var text = lines.joined(separator: " ")
        let inline: [(String, String)] = [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"),          // ![alt](src)
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),           // [text](url)
            (#"<((?:https?|mailto):[^>\s]+)>"#, "$1"),   // <https://…>
            (#"`+([^`]+?)`+"#, "$1"),                    // `code`, ``code``
            (#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, "$2"),   // **bold**, __bold__
            (#"~~(?=\S)(.+?)(?<=\S)~~"#, "$1"),          // ~~strike~~
            (#"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])"#, "$1"), // *italic*
            (#"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])"#, "$1"),   // _italic_
        ]
        for (pattern, template) in inline {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The preview while an approval card waits: "Waiting for you", the transcript's own status
    /// line (the card says what it asks), never the typing dots.
    static var waitingForYou: String {
        String(localized: "chief.preview.waitingForYou", defaultValue: "Waiting for you")
    }

    /// The newest message's waiting approval prompt, nil when it has none.
    static func pendingApprovalPrompt(_ message: Message?) -> String? {
        guard let message, !message.isRetracted else { return nil }
        for case .approval(let ref) in message.parts where ref.decided == nil { return ref.prompt }
        return nil
    }
}
