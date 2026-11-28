/// How a Mac's avatar icon should render: an SF Symbol or a literal emoji.
enum MacAvatarIcon: Hashable {
    case symbol(String)
    case emoji(String)

    /// Resolve from a user override, falling back to a default SF Symbol.
    static func resolve(custom: String?, defaultSymbol: String) -> MacAvatarIcon {
        guard let custom, !custom.isEmpty else { return .symbol(defaultSymbol) }
        if custom.unicodeScalars.contains(where: { $0.value > 127 }) { return .emoji(custom) }
        return .symbol(custom)
    }
}
