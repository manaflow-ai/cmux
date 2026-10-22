import AppKit

/// The vault list's colors, resolved in its host's theme scope (`VaultHostView`).
nonisolated struct VaultColors: Equatable, Sendable {
    var background: NSColor = .clear
    var primary: NSColor = .labelColor
    var secondary: NSColor = .secondaryLabelColor
    var tertiary: NSColor = .tertiaryLabelColor
    var selection: NSColor = .clear
    var live: NSColor = .systemGreen
}
