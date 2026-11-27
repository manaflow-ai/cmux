package import SwiftUI

/// The vault list's colors, resolved in its host's theme scope (`VaultHostView`).
package nonisolated struct VaultColors: Equatable, Sendable {
    package var background: Color = .clear
    package var primary: Color = .primary
    package var secondary: Color = .secondary
    package var tertiary: Color = .secondary
    package var selection: Color = .clear
    package var live: Color = .green

    package init(background: Color = .clear, primary: Color = .primary, secondary: Color = .secondary, tertiary: Color = .secondary, selection: Color = .clear, live: Color = .green) {
        self.background = background
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
        self.selection = selection
        self.live = live
    }
}
