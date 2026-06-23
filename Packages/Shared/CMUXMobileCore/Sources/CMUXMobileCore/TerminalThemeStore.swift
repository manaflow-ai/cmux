import Foundation

/// Process-wide holder for the active ``TerminalTheme``.
///
/// The embedded ghostty runtime renders from this theme, and the SwiftUI/UIKit
/// chrome around the terminal (letterbox fills, the input accessory bar) reads
/// the same value so it blends with the live terminal under any theme rather
/// than a hardcoded Monokai color. Reads and writes are serialized by a lock so
/// the value is safe to access from any thread.
public enum TerminalThemeStore {
    nonisolated(unsafe) private static var storage: TerminalTheme = .monokai
    private static let lock = NSLock()

    /// The active theme, defaulting to ``TerminalTheme/monokai``.
    public static var current: TerminalTheme {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Sets the active theme. An invalid or `nil` theme falls back to Monokai so
    /// the terminal always renders with a complete palette.
    public static func set(_ theme: TerminalTheme?) {
        let resolved = theme?.validatedOrDefault() ?? .monokai
        lock.lock()
        storage = resolved
        lock.unlock()
    }
}
