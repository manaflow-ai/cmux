import AppKit
import Observation
import SwiftUI

/// Colors of the pane, resolved by the host view inside its theme scope.
/// `ansi` is the terminal theme's 16-color palette: status and label colors
/// are palette indices, so Tasks always matches the user's Ghostty theme.
struct TasksColors: Equatable {
    var background = Color(nsColor: .windowBackgroundColor)
    /// What the page paints behind its lists (`Palette.paneFill`).
    var surface = Color.clear
    var elevated = Color(nsColor: .controlBackgroundColor)
    var primary = Color(nsColor: .labelColor)
    var secondary = Color(nsColor: .secondaryLabelColor)
    var tertiary = Color(nsColor: .tertiaryLabelColor)
    var hover = Color(nsColor: .quaternaryLabelColor)
    var selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    var separator = Color(nsColor: .separatorColor)
    var attention = Color(nsColor: .systemOrange)
    var danger = Color(nsColor: .systemRed)
    var success = Color(nsColor: .systemGreen)
    var shadow = Color.black.opacity(0.2)
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
