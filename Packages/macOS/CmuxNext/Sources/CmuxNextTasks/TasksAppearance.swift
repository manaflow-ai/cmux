import AppKit
import CmuxNextDesign
import Observation
import SwiftUI

/// Colors of the pane, resolved by the host view inside its theme scope; until then the app
/// theme's (`ThemeTokens.unresolved`), never macOS's grays.
/// `ansi` is the terminal theme's 16-color palette: status and label colors
/// are palette indices, so Tasks always matches the user's Ghostty theme.
struct TasksColors: Equatable {
    var background = ThemeTokens.unresolved.contentBackground.withAlpha(1).swiftUIColor
    /// What the page paints behind its lists (`Palette.paneFill`).
    var surface = Color.clear
    /// Whether `surface` hides what scrolls under it (an opaque window).
    var surfaceIsOpaque = false
    var elevated = ThemeTokens.unresolved.elevatedBackground.swiftUIColor
    var primary = ThemeTokens.unresolved.textPrimary.swiftUIColor
    var secondary = ThemeTokens.unresolved.textSecondary.swiftUIColor
    var tertiary = ThemeTokens.unresolved.textTertiary.swiftUIColor
    var hover = ThemeTokens.unresolved.hoverFill.swiftUIColor
    var selection = ThemeTokens.unresolved.selectionFill.swiftUIColor
    var separator = ThemeTokens.unresolved.separator.swiftUIColor
    var attention = ThemeTokens.unresolved.attention.swiftUIColor
    var danger = ThemeTokens.unresolved.danger.swiftUIColor
    var success = ThemeTokens.unresolved.success.swiftUIColor
    var shadow = ThemeTokens.unresolved.shadow.swiftUIColor
    var ansi: [Color] = []

    /// Palette entry `index`, falling back to secondary text.
    func ansi(_ index: Int) -> Color {
        ansi.indices.contains(index) ? ansi[index] : secondary
    }
}

@Observable
final class TasksAppearance {
    var colors = TasksColors()
}

extension EnvironmentValues {
    @Entry var tasksColors = TasksColors()
}
