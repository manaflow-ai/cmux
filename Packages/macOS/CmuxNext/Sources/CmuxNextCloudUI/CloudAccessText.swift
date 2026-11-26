/// How a moved chat's file or secret ask card (the App's `CloudAccessCard`) shortens a path or reason it shows.
public struct CloudAccessText {
    public init() {}
    /// The longest path or reason a card shows, in Unicode scalars.
    public static let longest = 200

    /// `text` with its middle cut to at most `limit` Unicode scalars.
    public static func middle(_ text: String, _ limit: Int = longest) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count > limit, limit > 2 else { return text }
        let head = (limit - 1) / 2, tail = limit - 1 - head
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[..<head])
        view.append("…")
        view.append(contentsOf: scalars[(scalars.count - tail)...])
        return String(view)
    }

    /// `text` cut to at most ``longest`` Unicode scalars.
    public static func prefix(_ text: String) -> String {
        guard text.unicodeScalars.count > longest else { return text }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: text.unicodeScalars.prefix(longest - 1))
        view.append("…")
        return String(view)
    }
}
