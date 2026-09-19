import Foundation

/// The visual content encoded by a sidebar status entry's `icon` token.
public enum SidebarStatusIcon: Equatable, Sendable {
    /// An SF Symbol. Bare icon tokens are treated as symbols for compatibility.
    case systemSymbol(String)
    /// An emoji rendered as text.
    case emoji(String)
    /// A short text badge.
    case text(String)
    /// A local image file. Relative paths are intentionally unsupported because
    /// the cmux app's working directory is unrelated to the invoking shell.
    case imageFile(String)

    /// Parses the icon token accepted by `set_status --icon`.
    public init?(token: String?) {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        for (prefix, makeIcon) in [
            ("emoji:", Self.emoji),
            ("text:", Self.text),
            ("image:", Self.imageFile),
            ("sf:", Self.systemSymbol),
        ] {
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = String(trimmed.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            self = makeIcon(value)
            return
        }

        self = .systemSymbol(trimmed)
    }
}

extension SidebarStatusEntry {
    /// Parsed visual content for the status row's icon token.
    public var sidebarIcon: SidebarStatusIcon? {
        SidebarStatusIcon(token: icon)
    }
}
