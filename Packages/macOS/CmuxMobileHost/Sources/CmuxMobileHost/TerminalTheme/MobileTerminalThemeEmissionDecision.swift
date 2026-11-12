public import CMUXMobileCore

public struct MobileTerminalThemeEmissionDecision: Equatable {
    public let theme: TerminalTheme
    public let shouldScheduleCandidate: Bool

    public init(
        theme: TerminalTheme,
        shouldScheduleCandidate: Bool
    ) {
        self.theme = theme
        self.shouldScheduleCandidate = shouldScheduleCandidate
    }

    public static func resolve(
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

    public static func resolveConfigTheme(
        candidate: TerminalTheme?,
        cached: TerminalTheme?,
        fallbackBoldColor: String? = nil,
        fallbackRendering: TerminalTheme.Rendering? = nil
    ) -> TerminalTheme? {
        guard var resolved = candidate ?? cached else { return nil }
        if resolved.boldColor == nil {
            resolved.boldColor = fallbackBoldColor
        }
        // The renderer exports colors only. The phone builds each surface's
        // Ghostty config from this theme, so it carries the Mac's rendering
        // settings too.
        if resolved.rendering == nil {
            resolved.rendering = fallbackRendering
        }
        return resolved
    }
}
