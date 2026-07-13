#if DEBUG
import SwiftUI

/// Resolves Atelier's exact light and dark color tokens for the active scheme.
struct AtelierTheme {
    let background: Color
    let card: Color
    let inset: Color
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let accentForeground: Color
    let needsYou: Color
    let running: Color
    let done: Color
    let failed: Color
    let idle: Color
    let cardShadow: Color
    let terminalBackground: Color
    let terminalPlain: Color
    let terminalDim: Color
    let terminalAccent: Color
    let terminalSuccess: Color
    let terminalWarning: Color
    let terminalError: Color

    init(scheme: ColorScheme) {
        if scheme == .dark {
            background = Color(red: 32.0 / 255.0, green: 28.0 / 255.0, blue: 24.0 / 255.0)
            card = Color(red: 42.0 / 255.0, green: 37.0 / 255.0, blue: 31.0 / 255.0)
            inset = Color(red: 54.0 / 255.0, green: 48.0 / 255.0, blue: 40.0 / 255.0)
            hairline = Color(red: 237.0 / 255.0, green: 231.0 / 255.0, blue: 222.0 / 255.0).opacity(0.10)
            textPrimary = Color(red: 237.0 / 255.0, green: 231.0 / 255.0, blue: 222.0 / 255.0)
            textSecondary = Color(red: 179.0 / 255.0, green: 169.0 / 255.0, blue: 156.0 / 255.0)
            textTertiary = Color(red: 122.0 / 255.0, green: 113.0 / 255.0, blue: 102.0 / 255.0)
            accent = Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
            needsYou = Color(red: 217.0 / 255.0, green: 160.0 / 255.0, blue: 63.0 / 255.0)
            running = Color(red: 143.0 / 255.0, green: 165.0 / 255.0, blue: 181.0 / 255.0)
            done = Color(red: 140.0 / 255.0, green: 171.0 / 255.0, blue: 132.0 / 255.0)
            failed = Color(red: 204.0 / 255.0, green: 107.0 / 255.0, blue: 85.0 / 255.0)
            idle = Color(red: 122.0 / 255.0, green: 113.0 / 255.0, blue: 102.0 / 255.0)
            cardShadow = .clear
        } else {
            background = Color(red: 247.0 / 255.0, green: 243.0 / 255.0, blue: 236.0 / 255.0)
            card = Color(red: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0)
            inset = Color(red: 239.0 / 255.0, green: 233.0 / 255.0, blue: 222.0 / 255.0)
            hairline = Color(red: 42.0 / 255.0, green: 37.0 / 255.0, blue: 32.0 / 255.0).opacity(0.10)
            textPrimary = Color(red: 42.0 / 255.0, green: 37.0 / 255.0, blue: 32.0 / 255.0)
            textSecondary = Color(red: 107.0 / 255.0, green: 98.0 / 255.0, blue: 89.0 / 255.0)
            textTertiary = Color(red: 163.0 / 255.0, green: 155.0 / 255.0, blue: 143.0 / 255.0)
            accent = Color(red: 193.0 / 255.0, green: 95.0 / 255.0, blue: 60.0 / 255.0)
            needsYou = Color(red: 176.0 / 255.0, green: 120.0 / 255.0, blue: 24.0 / 255.0)
            running = Color(red: 95.0 / 255.0, green: 116.0 / 255.0, blue: 132.0 / 255.0)
            done = Color(red: 95.0 / 255.0, green: 125.0 / 255.0, blue: 88.0 / 255.0)
            failed = Color(red: 168.0 / 255.0, green: 70.0 / 255.0, blue: 50.0 / 255.0)
            idle = Color(red: 163.0 / 255.0, green: 155.0 / 255.0, blue: 143.0 / 255.0)
            cardShadow = Color.black.opacity(0.06)
        }

        terminalBackground = Color(red: 32.0 / 255.0, green: 28.0 / 255.0, blue: 24.0 / 255.0)
        accentForeground = Color(red: 255.0 / 255.0, green: 255.0 / 255.0, blue: 255.0 / 255.0)
        terminalPlain = Color(red: 237.0 / 255.0, green: 231.0 / 255.0, blue: 222.0 / 255.0)
        terminalDim = Color(red: 179.0 / 255.0, green: 169.0 / 255.0, blue: 156.0 / 255.0)
        terminalAccent = Color(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 87.0 / 255.0)
        terminalSuccess = Color(red: 140.0 / 255.0, green: 171.0 / 255.0, blue: 132.0 / 255.0)
        terminalWarning = Color(red: 217.0 / 255.0, green: 160.0 / 255.0, blue: 63.0 / 255.0)
        terminalError = Color(red: 204.0 / 255.0, green: 107.0 / 255.0, blue: 85.0 / 255.0)
    }

    /// Returns the semantic color for a shared fixture state.
    func color(for state: GalleryAgentState) -> Color {
        switch state {
        case .needsYou: needsYou
        case .running: running
        case .done: done
        case .failed: failed
        case .idle: idle
        }
    }

    /// Returns Atelier's plain-language label for a shared fixture state.
    func label(for state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "Waiting for you"
        case .running: "Working…"
        case .done: "Finished"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    /// Returns a redundant symbol encoding for a shared fixture state.
    func symbol(for state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "exclamationmark"
        case .running: "arrow.trianglehead.2.clockwise.rotate.90"
        case .done: "checkmark"
        case .failed: "xmark"
        case .idle: "pause.fill"
        }
    }
}
#endif
