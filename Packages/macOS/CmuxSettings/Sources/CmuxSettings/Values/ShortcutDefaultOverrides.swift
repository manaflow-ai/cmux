import Foundation

/// Host-installed dynamic default strokes.
///
/// cmux resolves the right-sidebar digit defaults positionally from the user's
/// visible tab order, which lives in host-owned state this package cannot
/// read. The host installs a provider at launch; every package consumer of
/// ``ShortcutAction/defaultStroke`` (the Settings UI's effective-shortcut
/// resolution, legacy conflict checks) then agrees with the app's runtime
/// defaults. Without a provider (package tests, other hosts) the static table
/// in `ShortcutAction+Defaults.swift` answers unchanged.
public enum ShortcutDefaultOverrides {
    /// What the host wants for one action's factory default.
    public enum Result: Sendable {
        /// Use the package's built-in static table.
        case useBuiltIn
        /// Use this stroke; `nil` means the action defaults to unbound.
        case stroke(ShortcutStroke?)
    }

    public typealias Provider = @Sendable (ShortcutAction) -> Result

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: Provider?

    /// Installs (or clears) the host provider. Call once at launch, before
    /// shortcut resolution begins; the provider itself must read live state so
    /// later preference changes need no re-install.
    public static func install(_ provider: Provider?) {
        lock.lock()
        defer { lock.unlock() }
        _provider = provider
    }

    static func result(for action: ShortcutAction) -> Result {
        lock.lock()
        let provider = _provider
        lock.unlock()
        return provider?(action) ?? .useBuiltIn
    }
}
