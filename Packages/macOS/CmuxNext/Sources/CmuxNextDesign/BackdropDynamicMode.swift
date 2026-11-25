/// How a dynamic macOS wallpaper changes (`appearance.backgroundDynamic`).
public nonisolated enum BackdropDynamicMode: String, CaseIterable, Sendable {
    /// Its light or dark frame, with the window's appearance.
    case appearance
    /// Its frames through the day, like macOS's Dynamic desktop: by the sun, or by the clock.
    case time
}
