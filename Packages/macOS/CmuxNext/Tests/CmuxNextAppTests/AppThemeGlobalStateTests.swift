import Testing

/// Suites that change the app-wide theme (ThemeStore, ThemeScope.app,
/// Ghostty background override) or read it in pixels run one after another:
/// Swift Testing runs separate suites in parallel, and a translucent theme
/// set by one suite made another's opaque-window pixel check flaky.
@MainActor @Suite(.serialized) struct AppThemeGlobalStateTests {}
