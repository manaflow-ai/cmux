/// Printable text captured by the New Tab action until its field can accept input.
struct NewTabInputBuffer: Equatable {
    static let maxCharacters = 256
    private(set) var text = ""

    mutating func append(_ characters: String) {
        text += characters.prefix(max(0, Self.maxCharacters - text.count))
    }

    mutating func take() -> String? {
        guard !text.isEmpty else { return nil }
        defer { text.removeAll(keepingCapacity: true) }
        return text
    }
}
