import Foundation

/// Process-wide holder for the active ``TerminalTheme``.
///
/// The iOS shell owns authoritative per-surface themes and projects the selected
/// value here for the process-wide embedded Ghostty runtime and SwiftUI chrome.
/// UIKit surface chrome keeps the assigned per-surface value directly. Every
/// producer and consumer runs on the main
/// actor (the shell's theme sync, the ghostty runtime, and the SwiftUI/UIKit
/// chrome), so the store is `@MainActor`-isolated rather than guarding a mutable
/// static behind a lock: the compiler proves all access stays on the main actor,
/// and reads stay synchronous for string interpolation and view bodies.
///
/// Intentionally a process-wide singleton holder for one global rendering
/// resource (the active theme), not dependency-bearing logic that belongs on an
/// instantiated value; main-actor isolated for safe sharing.
/// lint:allow namespace-type — global rendering-resource singleton, see above.
@MainActor
public struct TerminalThemeStore {
    private init() {}
    private static var storage: TerminalTheme = .monokai

    /// The active theme, defaulting to ``TerminalTheme/monokai``.
    public static var current: TerminalTheme { storage }

    /// Sets the active theme. An invalid or `nil` theme falls back to Monokai so
    /// the terminal always renders with a complete palette.
    public static func set(_ theme: TerminalTheme?) {
        storage = theme?.validatedOrDefault() ?? .monokai
    }
}
