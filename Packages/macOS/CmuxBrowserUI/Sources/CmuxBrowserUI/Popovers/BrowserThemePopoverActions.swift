/// Main-actor action closures the browser-theme popover rows invoke.
///
/// The single closure runs the app-side mutation (apply the selected theme mode
/// keyed by its raw value). Keeping the side effect behind a closure lets the
/// popover view live in this package while the panel mutation and the `@State`
/// popover dismissal stay on the app-side forwarder.
public struct BrowserThemePopoverActions {
    /// Apply the theme mode identified by its raw value (the forwarder also
    /// dismisses the popover).
    public var onSelectThemeMode: @MainActor (String) -> Void

    /// Creates the theme popover action bundle.
    public init(onSelectThemeMode: @escaping @MainActor (String) -> Void) {
        self.onSelectThemeMode = onSelectThemeMode
    }
}
