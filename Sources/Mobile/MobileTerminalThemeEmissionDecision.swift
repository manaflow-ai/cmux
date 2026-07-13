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
        cached: TerminalTheme?
    ) -> TerminalTheme? {
        candidate ?? cached
    }
}
