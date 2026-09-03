public import OSLog

/// Shared logging identity for the local Linux feature. The package and the
/// app feature module log under the same subsystem and category so one
/// `log stream` predicate covers the kernel bridge, controller, and view.
public nonisolated enum LocalLinuxLog {
    public static let subsystem = "dev.cmux.ios"
    public static let category = "local-linux"

    /// Logger used by every local Linux component.
    public static let logger = Logger(subsystem: subsystem, category: category)
}

/// Accessibility identifiers shared by the production view and test harnesses.
public nonisolated enum LocalLinuxAccessibilityIdentifier {
    /// The container that hosts the local terminal, including its overlay.
    public static let terminal = "cmux.local-linux.terminal"
    /// The Ghostty surface rendering the local shell.
    public static let surface = "cmux.local-linux.surface"
}
