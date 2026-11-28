import AppKit
import Observation
import SwiftUI

/// Colors of the pane, resolved by the host view inside its theme scope
/// (rooms and workspaces can each have their own theme). SwiftUI views read
/// them from the environment and never touch `Palette`.
struct AgentActivityColors: Equatable {
    var background = Color(nsColor: .windowBackgroundColor)
    var sidebar = Color(nsColor: .underPageBackgroundColor)
    var elevated = Color(nsColor: .controlBackgroundColor)
    var primary = Color(nsColor: .labelColor)
    var secondary = Color(nsColor: .secondaryLabelColor)
    var tertiary = Color(nsColor: .tertiaryLabelColor)
    var hover = Color(nsColor: .quaternaryLabelColor)
    var selection = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    var badge = Color(nsColor: .quaternaryLabelColor)
    var separator = Color(nsColor: .separatorColor)
    var danger = Color(nsColor: .systemRed)
    var success = Color(nsColor: .systemGreen)
    var attention = Color(nsColor: .systemOrange)
    var shadow = Color.black.opacity(0.2)
}

@Observable
final class AgentActivityAppearance {
    var colors = AgentActivityColors()
}

extension EnvironmentValues {
    @Entry var agentActivityColors = AgentActivityColors()
}
