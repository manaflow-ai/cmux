import SwiftUI

/// The vault list's colors, resolved in its host's theme scope (`VaultHostView`).
nonisolated struct VaultColors: Equatable, Sendable {
    var background: Color = .clear
    var primary: Color = .primary
    var secondary: Color = .secondary
    var tertiary: Color = .secondary
    var selection: Color = .clear
    var live: Color = .green
}
