#if DEBUG
import SwiftUI

/// Resolves every Phosphor palette token for the gallery's current color scheme.
struct PhosphorTheme {
    let isDark: Bool
    let bg0: Color
    let bg1: Color
    let bg2: Color
    let hairline: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let accent: Color
    let statusNeedsYou: Color
    let statusRunning: Color
    let statusDone: Color
    let statusFailed: Color
    let statusIdle: Color

    init(scheme: ColorScheme) {
        isDark = scheme == .dark

        if scheme == .dark {
            bg0 = Color(red: 10.0 / 255.0, green: 11.0 / 255.0, blue: 13.0 / 255.0)
            bg1 = Color(red: 17.0 / 255.0, green: 19.0 / 255.0, blue: 24.0 / 255.0)
            bg2 = Color(red: 26.0 / 255.0, green: 29.0 / 255.0, blue: 36.0 / 255.0)
            hairline = Color(red: 1.0, green: 1.0, blue: 1.0).opacity(0.08)
            textPrimary = Color(red: 232.0 / 255.0, green: 234.0 / 255.0, blue: 237.0 / 255.0)
            textSecondary = Color(red: 155.0 / 255.0, green: 161.0 / 255.0, blue: 172.0 / 255.0)
            textTertiary = Color(red: 92.0 / 255.0, green: 99.0 / 255.0, blue: 112.0 / 255.0)
            accent = Color(red: 77.0 / 255.0, green: 157.0 / 255.0, blue: 1.0)
            statusNeedsYou = Color(red: 1.0, green: 178.0 / 255.0, blue: 36.0 / 255.0)
            statusRunning = Color(red: 77.0 / 255.0, green: 157.0 / 255.0, blue: 1.0)
            statusDone = Color(red: 61.0 / 255.0, green: 214.0 / 255.0, blue: 140.0 / 255.0)
            statusFailed = Color(red: 1.0, green: 93.0 / 255.0, blue: 93.0 / 255.0)
            statusIdle = Color(red: 92.0 / 255.0, green: 99.0 / 255.0, blue: 112.0 / 255.0)
        } else {
            bg0 = Color(red: 242.0 / 255.0, green: 243.0 / 255.0, blue: 245.0 / 255.0)
            bg1 = Color(red: 1.0, green: 1.0, blue: 1.0)
            bg2 = Color(red: 233.0 / 255.0, green: 235.0 / 255.0, blue: 238.0 / 255.0)
            hairline = Color(red: 0.0, green: 0.0, blue: 0.0).opacity(0.10)
            textPrimary = Color(red: 26.0 / 255.0, green: 29.0 / 255.0, blue: 36.0 / 255.0)
            textSecondary = Color(red: 92.0 / 255.0, green: 99.0 / 255.0, blue: 112.0 / 255.0)
            textTertiary = Color(red: 155.0 / 255.0, green: 161.0 / 255.0, blue: 172.0 / 255.0)
            accent = Color(red: 29.0 / 255.0, green: 111.0 / 255.0, blue: 224.0 / 255.0)
            statusNeedsYou = Color(red: 184.0 / 255.0, green: 119.0 / 255.0, blue: 0.0)
            statusRunning = Color(red: 29.0 / 255.0, green: 111.0 / 255.0, blue: 224.0 / 255.0)
            statusDone = Color(red: 23.0 / 255.0, green: 128.0 / 255.0, blue: 79.0 / 255.0)
            statusFailed = Color(red: 201.0 / 255.0, green: 48.0 / 255.0, blue: 48.0 / 255.0)
            statusIdle = Color(red: 155.0 / 255.0, green: 161.0 / 255.0, blue: 172.0 / 255.0)
        }
    }

    func statusColor(_ state: GalleryAgentState) -> Color {
        switch state {
        case .needsYou: statusNeedsYou
        case .running: statusRunning
        case .done: statusDone
        case .failed: statusFailed
        case .idle: statusIdle
        }
    }

    func statusLabel(_ state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "Needs you"
        case .running: "Running"
        case .done: "Done"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    func statusSymbol(_ state: GalleryAgentState) -> String {
        switch state {
        case .needsYou: "exclamationmark"
        case .running: "waveform.path.ecg"
        case .done: "checkmark"
        case .failed: "xmark"
        case .idle: "minus"
        }
    }

    func statusRank(_ state: GalleryAgentState) -> Int {
        switch state {
        case .needsYou: 0
        case .failed: 1
        case .running: 2
        case .done: 3
        case .idle: 4
        }
    }

    func isNeedsYou(_ state: GalleryAgentState) -> Bool {
        if case .needsYou = state {
            true
        } else {
            false
        }
    }

    func terminalColor(_ tone: GalleryTerminalLine.Tone) -> Color {
        switch tone {
        case .plain: textPrimary
        case .dim: textTertiary
        case .accent: accent
        case .success: statusDone
        case .warning: statusNeedsYou
        case .error: statusFailed
        }
    }
}
#endif
