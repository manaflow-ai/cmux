/// How a Mac's avatar icon should render: an SF Symbol, a literal emoji, or a
/// bundled built-in agent logo image (Claude, Codex, OpenCode, pi, …).
///
/// The custom string is stored/synced as a single opaque value. A value that
/// starts with ``logoPrefix`` (`"logo:"`) selects a bundled logo by its stable
/// identifier (e.g. `"logo:claude"`); anything containing a non-ASCII scalar is
/// treated as an emoji; everything else is an SF Symbol name. Older clients that
/// don't understand the `logo:` prefix fall through to the symbol case and try
/// to render the literal string as an SF Symbol (an unknown symbol renders
/// nothing), so the field stays backward compatible.
enum MacAvatarIcon: Hashable {
    case symbol(String)
    case emoji(String)
    case image(String)

    /// Marks a custom avatar string as a built-in logo identifier on the wire.
    static let logoPrefix = "logo:"

    /// Encode a built-in logo identifier into the stored/synced string form.
    static func logoValue(_ identifier: String) -> String {
        logoPrefix + identifier
    }

    /// Resolve a single override string, falling back to a default SF Symbol.
    static func resolve(custom: String?, defaultSymbol: String) -> MacAvatarIcon {
        classify(custom) ?? .symbol(defaultSymbol)
    }

    /// Resolve with per-workspace precedence: a per-workspace avatar override
    /// wins over the owning Mac's icon, which wins over the default SF Symbol.
    static func resolve(
        workspaceAvatar: String?,
        machineCustomIcon: String?,
        defaultSymbol: String
    ) -> MacAvatarIcon {
        classify(workspaceAvatar) ?? classify(machineCustomIcon) ?? .symbol(defaultSymbol)
    }

    /// Classify a raw override string into an icon, or `nil` when empty/absent.
    private static func classify(_ value: String?) -> MacAvatarIcon? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix(logoPrefix) {
            let identifier = String(value.dropFirst(logoPrefix.count))
            return identifier.isEmpty ? nil : .image(identifier)
        }
        if value.unicodeScalars.contains(where: { $0.value > 127 }) { return .emoji(value) }
        return .symbol(value)
    }
}
