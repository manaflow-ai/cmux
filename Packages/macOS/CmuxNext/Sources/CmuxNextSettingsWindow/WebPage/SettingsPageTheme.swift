import CmuxNextDesign
import Foundation

/// The theme the web Settings page reads as CSS variables, in the agent
/// pane's key names (`window.cmuxSettingsBridge.applyTheme`). It carries no
/// background: the page and every container are transparent, so the
/// window's one backdrop shows through (plans/cmux-next/windows.md).
enum SettingsPageTheme {
    static func values(_ tokens: ThemeTokens, motion: MotionPolicy = Motion.policy) -> [String: Any] {
        [
            "isDark": tokens.isDark,
            "inputBackground": css(tokens.hoverFill),
            "border": Borders.drawsLines ? css(tokens.separator) : "transparent",
            "borderStrong": Borders.drawsLines ? css(tokens.paneBorder) : "transparent",
            "borders": Borders.current.mode.rawValue,
            "text": css(tokens.textPrimary),
            "mutedText": css(tokens.textSecondary),
            "softText": css(tokens.textTertiary),
            "accent": css(tokens.textPrimary),
            "accentSoft": css(tokens.selectionFill),
            "danger": css(tokens.danger),
            "warning": css(tokens.attention),
            "highlight": css(tokens.highlight),
            "highlightText": css(tokens.highlightText),
            "motion": [
                "hover": motion.duration(MotionFade.hover),
                "focus": motion.duration(MotionFade.focus),
                "fadeIn": motion.duration(MotionFade.fadeIn),
                "fadeOut": motion.duration(MotionFade.fadeOut),
            ],
        ]
    }

    static func css(_ color: ThemeRGB) -> String {
        func channel(_ value: Double) -> Int { Int((value * 255).rounded()) }
        let alpha = (color.alpha * 1000).rounded() / 1000
        return "rgba(\(channel(color.red)), \(channel(color.green)), \(channel(color.blue)), \(alpha))"
    }
}
