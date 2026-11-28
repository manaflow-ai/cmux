extension DiffHunk {
    /// Unified-diff text copied by the line context menu.
    public var copyText: String {
        ([header] + lines).compactMap { line in
            switch line.kind {
            case .hunkHeader: line.text
            case .addition: "+" + line.text
            case .removal: "-" + line.text
            case .context: " " + line.text
            case .noNewlineMarker: nil
            }
        }
        .joined(separator: "\n")
    }
}
