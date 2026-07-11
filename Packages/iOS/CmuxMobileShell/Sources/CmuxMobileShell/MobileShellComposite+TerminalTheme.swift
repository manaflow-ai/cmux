public import CMUXMobileCore

extension MobileShellComposite {
    /// Applies the host-wide theme reported during connection negotiation.
    /// - Parameter theme: The Mac's resolved theme, or `nil` for a legacy host.
    public func applyTerminalTheme(_ theme: TerminalTheme?) {
        terminalThemeState.hostTheme = theme?.validatedOrDefault() ?? .monokai
        applySelectedTerminalTheme()
    }

    /// Records a full render-grid frame's theme for its surface and updates the
    /// active chrome when that surface is selected.
    func recordTerminalTheme(_ frame: MobileTerminalRenderGridFrame) {
        guard frame.full, let theme = frame.terminalTheme?.validatedOrDefault() else { return }
        terminalThemeState.themesBySurfaceID[frame.surfaceID] = theme
        if selectedTerminalID?.rawValue == frame.surfaceID {
            setActiveTerminalTheme(theme)
        }
    }

    /// Returns the most recent theme for one surface, falling back to the
    /// connected Mac's host-wide theme before its first full frame arrives.
    func terminalTheme(for surfaceID: String) -> TerminalTheme {
        terminalThemeState.theme(for: surfaceID)
    }

    func applySelectedTerminalTheme() {
        let theme = selectedTerminalID.map { terminalTheme(for: $0.rawValue) }
            ?? terminalThemeState.hostTheme
        setActiveTerminalTheme(theme)
    }

    func resetTerminalThemes() {
        terminalThemeState = MobileTerminalThemeState()
        TerminalThemeStore.set(.monokai)
    }

    private func setActiveTerminalTheme(_ theme: TerminalTheme) {
        guard terminalThemeState.activeTheme != theme || TerminalThemeStore.current != theme else { return }
        terminalThemeState.activeTheme = theme
        TerminalThemeStore.set(theme)
        terminalThemeState.generation &+= 1
    }
}
