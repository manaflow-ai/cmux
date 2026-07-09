/// How a browser panel is being created, which governs whether the panel may
/// be created while the browser feature is globally disabled and whether its
/// initial navigation preloads off-screen.
///
/// - `userInitiated`: a direct user action (new browser tab/split, omnibar
///   open). Refused when the browser feature is disabled.
/// - `automationPreload`: a programmatic preload (e.g. automation warming a
///   navigation before the surface is shown), so the initial navigation runs
///   in the background.
/// - `restoration`: rebuilding a saved session surface. Permitted even when the
///   browser feature is disabled so a restored layout is not silently dropped.
public enum BrowserPanelCreationPolicy: Sendable, Equatable {
    case userInitiated
    case automationPreload
    case restoration

    /// Whether a panel may be created while the browser feature is disabled.
    /// Only session restoration is allowed to materialize a disabled-feature
    /// surface so a saved layout survives a toggle-off.
    public var permitsCreationWhenBrowserDisabled: Bool {
        self == .restoration
    }

    /// Whether the panel's initial navigation should preload in the background
    /// rather than render immediately. Only automation preloads do this.
    public var preloadsInitialNavigationInBackground: Bool {
        self == .automationPreload
    }
}
