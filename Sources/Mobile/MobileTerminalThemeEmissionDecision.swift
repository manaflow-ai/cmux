import CMUXMobileCore

struct MobileTerminalThemeEmissionDecision: Equatable {
    let theme: TerminalTheme
    let shouldScheduleCandidate: Bool

    static func resolve(
        candidate: TerminalTheme,
        cached: TerminalTheme?,
        forceCandidate: Bool
    ) -> Self {
        guard let cached, !forceCandidate else {
            return Self(theme: candidate, shouldScheduleCandidate: false)
        }
        return Self(
            theme: cached,
            shouldScheduleCandidate: candidate != cached
        )
    }

    static func resolveConfigTheme(
        candidate: TerminalTheme?,
        cached: TerminalTheme?,
        fallbackBoldColor: String? = nil
    ) -> TerminalTheme? {
        guard var resolved = candidate ?? cached else { return nil }
        if resolved.boldColor == nil {
            resolved.boldColor = fallbackBoldColor
        }
        return resolved
    }
}
