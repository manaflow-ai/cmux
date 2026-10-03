public import CmuxTheme


extension ThemeTokens {
    /// The one background of every window and the surfaces on it
    /// (plans/cmux-next/windows.md): the terminal background with its
    /// `background-opacity`. Views on it draw nothing of their own (clear)
    /// or exactly this.
    public nonisolated var surfaceBackground: ThemeRGB { windowBackground }
}
