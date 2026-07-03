import Foundation

/// Process-wide holder for the active ``TerminalTheme``.
///
/// The embedded ghostty runtime renders from this theme, and the SwiftUI/UIKit
/// chrome around the terminal (letterbox fills, the input accessory bar) reads
/// the same value so it blends with the live terminal under any theme rather
/// than a hardcoded Monokai color. Every producer and consumer runs on the main
/// actor (the shell's theme sync, the ghostty runtime, and the SwiftUI/UIKit
/// chrome), so the store is `@MainActor`-isolated rather than guarding a mutable
/// static behind a lock: the compiler proves all access stays on the main actor,
/// and reads stay synchronous for string interpolation and view bodies.
@MainActor
public enum TerminalThemeStore {
    private static var storage: TerminalTheme = .monokai

    /// The active theme, defaulting to ``TerminalTheme/monokai``.
    public static var current: TerminalTheme { storage }

    /// Sets the active theme. An invalid or `nil` theme falls back to Monokai so
    /// the terminal always renders with a complete palette.
    public static func set(_ theme: TerminalTheme?) {
        storage = theme?.validatedOrDefault() ?? .monokai
    }
}
