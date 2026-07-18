#if DEBUG
import SwiftUI

/// Resolves the complete Signal color token set for the active appearance.
struct SignalTheme {
    let bg0: Color
    let surface: Color
    let ink: Color
    let secondaryText: Color
    let hairline: Color
    let needsYou: Color
    let running: Color
    let done: Color
    let failed: Color
    let idle: Color

    init(scheme: ColorScheme) {
        switch scheme {
        case .dark:
            bg0 = Color(red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0)
            surface = Color(red: 28.0 / 255.0, green: 28.0 / 255.0, blue: 26.0 / 255.0)
            ink = Color(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 240.0 / 255.0)
            secondaryText = Color(red: 163.0 / 255.0, green: 163.0 / 255.0, blue: 158.0 / 255.0)
            hairline = Color(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 240.0 / 255.0).opacity(0.14)
            needsYou = Color(red: 240.0 / 255.0, green: 180.0 / 255.0, blue: 41.0 / 255.0)
            running = Color(red: 74.0 / 255.0, green: 158.0 / 255.0, blue: 255.0 / 255.0)
            done = Color(red: 52.0 / 255.0, green: 196.0 / 255.0, blue: 113.0 / 255.0)
            failed = Color(red: 240.0 / 255.0, green: 85.0 / 255.0, blue: 74.0 / 255.0)
            idle = Color(red: 110.0 / 255.0, green: 110.0 / 255.0, blue: 105.0 / 255.0)
        default:
            bg0 = Color(red: 245.0 / 255.0, green: 245.0 / 255.0, blue: 244.0 / 255.0)
            surface = Color(red: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0)
            ink = Color(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0)
            secondaryText = Color(red: 85.0 / 255.0, green: 85.0 / 255.0, blue: 80.0 / 255.0)
            hairline = Color(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0).opacity(0.12)
            needsYou = Color(red: 232.0 / 255.0, green: 162.0 / 255.0, blue: 0.0 / 255.0)
            running = Color(red: 10.0 / 255.0, green: 122.0 / 255.0, blue: 255.0 / 255.0)
            done = Color(red: 31.0 / 255.0, green: 158.0 / 255.0, blue: 85.0 / 255.0)
            failed = Color(red: 217.0 / 255.0, green: 48.0 / 255.0, blue: 37.0 / 255.0)
            idle = Color(red: 138.0 / 255.0, green: 138.0 / 255.0, blue: 133.0 / 255.0)
        }
    }

    /// Returns the fixed Signal color assigned to an agent lifecycle state.
    func color(for state: GalleryAgentState) -> Color {
        switch state {
        case .needsYou: needsYou
        case .running: running
        case .done: done
        case .failed: failed
        case .idle: idle
        }
    }
}
#endif
