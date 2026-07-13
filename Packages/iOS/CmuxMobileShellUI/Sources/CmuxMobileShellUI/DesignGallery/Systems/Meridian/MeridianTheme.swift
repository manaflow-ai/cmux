#if DEBUG
import SwiftUI
import UIKit

/// Resolves Meridian's semantic system palette and exact indigo accent for one appearance.
struct MeridianTheme {
    let scheme: ColorScheme
    let background: Color
    let secondaryBackground: Color
    let tertiaryFill: Color
    let label: Color
    let secondaryLabel: Color
    let tertiaryLabel: Color
    let separator: Color
    let accentForeground: Color
    let accent: Color
    let needsYou: Color
    let running: Color
    let done: Color
    let failed: Color
    let idle: Color

    let cardRadius: CGFloat = 26
    let horizontalInset: CGFloat = 20

    init(scheme: ColorScheme) {
        self.scheme = scheme
        background = Color(uiColor: .systemBackground)
        secondaryBackground = Color(uiColor: .secondarySystemBackground)
        tertiaryFill = Color(uiColor: .tertiarySystemFill)
        label = Color(uiColor: .label)
        secondaryLabel = Color(uiColor: .secondaryLabel)
        tertiaryLabel = Color(uiColor: .tertiaryLabel)
        separator = Color(uiColor: .separator)
        accentForeground = Color(uiColor: .white)
        accent = scheme == .dark
            ? Color(red: 122.0 / 255.0, green: 122.0 / 255.0, blue: 232.0 / 255.0)
            : Color(red: 91.0 / 255.0, green: 91.0 / 255.0, blue: 214.0 / 255.0)
        needsYou = Color(uiColor: .systemOrange)
        running = accent
        done = Color(uiColor: .systemGreen)
        failed = Color(uiColor: .systemRed)
        idle = Color(uiColor: .tertiaryLabel)
    }

    /// Returns the redundantly encoded tint for an agent lifecycle state.
    func color(for state: GalleryAgentState) -> Color {
        switch state {
        case .needsYou: needsYou
        case .running: running
        case .done: done
        case .failed: failed
        case .idle: idle
        }
    }

    /// Returns Meridian's binding SF Symbol for an agent lifecycle state.
    func symbolName(for state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "person.crop.circle.badge.exclamationmark"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .idle: "moon.zzz"
        }
    }

    /// Returns the word paired with a status symbol so state never relies on color alone.
    func label(for state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    var backgroundHex: String { scheme == .dark ? "#000000" : "#FFFFFF" }
    var secondaryBackgroundHex: String { scheme == .dark ? "#1C1C1E" : "#F2F2F7" }
    var tertiaryFillHex: String { scheme == .dark ? "#7676803D" : "#7676801F" }
    var labelHex: String { scheme == .dark ? "#FFFFFF" : "#000000" }
    var secondaryLabelHex: String { scheme == .dark ? "#EBEBF599" : "#3C3C4399" }
    var tertiaryLabelHex: String { scheme == .dark ? "#EBEBF54D" : "#3C3C434D" }
    var accentHex: String { scheme == .dark ? "#7A7AE8" : "#5B5BD6" }
    var needsYouHex: String { scheme == .dark ? "#FF9F0A" : "#FF9500" }
    var doneHex: String { scheme == .dark ? "#30D158" : "#34C759" }
    var failedHex: String { scheme == .dark ? "#FF453A" : "#FF3B30" }
}
#endif
