import Foundation

/// Text the page asks to save where the user picks, through the pane's save panel
/// (``AgentPaneSavePanel``): the ACP inspector's export (`pane.saveLog`, JSON Lines) or a side
/// panel document (`pane.saveFile {text, suggestedName, kind}`, cx-ncc.75: HTML, SVG or Markdown).
/// At most ``AgentPaneRequest/maximumLogBytes`` UTF-8 bytes.
public nonisolated struct AgentPaneSave: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case log, html, svg, markdown

        /// The extension the saved file gets.
        public var fileExtension: String {
            switch self {
            case .log: "jsonl"
            case .html: "html"
            case .svg: "svg"
            case .markdown: "md"
            }
        }
    }

    public let text: String
    /// A plain file name ending in the kind's extension.
    public let suggestedName: String
    public let kind: Kind

    /// Nil unless `text` is non-empty and small enough.
    init?(text: Any?, suggestedName: Any?, kind: Kind) {
        guard let text = text as? String, !text.isEmpty, text.utf8.count <= AgentPaneRequest.maximumLogBytes else { return nil }
        self.text = text
        self.suggestedName = Self.fileName(suggestedName as? String, kind: kind)
        self.kind = kind
    }

    /// `name` as a plain file name with the kind's extension: path separators and control
    /// characters removed, no leading dots, at most 120 characters; `acp` (a log) or `document`
    /// when nothing usable is left.
    static func fileName(_ name: String?, kind: Kind) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: (name ?? "").unicodeScalars.filter { scalar in
            scalar != "/" && scalar != ":" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        let suffix = "." + kind.fileExtension
        var base = cleaned.lowercased().hasSuffix(suffix) ? String(cleaned.dropLast(suffix.count)) : cleaned
        base = String(base.prefix(120 - suffix.count))
        // Dots and spaces together, so ". .profile" never comes back as a hidden ".profile".
        while let first = base.first, first == "." || first.isWhitespace { base.removeFirst() }
        while base.last?.isWhitespace == true { base.removeLast() }
        return (base.isEmpty ? (kind == .log ? "acp" : "document") : base) + suffix
    }
}
