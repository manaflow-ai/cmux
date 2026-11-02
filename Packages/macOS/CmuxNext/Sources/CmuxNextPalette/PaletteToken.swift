/// One chosen value of a multi-value step, drawn as a chip in the search field (New Group Chat's
/// members). A click on it, or Backspace on an empty query when it is the last one, shows
/// `remove()`: the same page without it.
public struct PaletteToken {
    /// Stable value (a participant id or typed address).
    public let id: String
    /// The chip's text.
    public let title: String
    /// SF Symbol drawn before the title.
    public let symbol: String
    /// The page with this value removed.
    public let remove: @MainActor () -> PalettePageSpec

    public init(id: String, title: String, symbol: String = "person.fill", remove: @escaping @MainActor () -> PalettePageSpec) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.remove = remove
    }
}
