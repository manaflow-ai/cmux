public import Foundation

/// Stable identity of one cmux main window.
///
/// A typed wrapper over the `UUID` the app target already assigns to each main
/// window, introduced so per-window state can be keyed by a single value
/// identity instead of an `NSWindow`/`TabManager` `ObjectIdentifier`. Each
/// domain package owns its own `[WindowID: Model]` keyed by this value (owner
/// ruling 2026-06-18: per-window state is domain-owned and `WindowID`-keyed,
/// never bundled into one per-window aggregate).
///
/// `Sendable`/`Hashable` so it crosses isolation boundaries and serves as a
/// dictionary key. It carries no behavior beyond identity; the `NSWindow`
/// handle and the per-window models live with their owners, not here.
public struct WindowID: Hashable, Sendable {
    /// The underlying window identifier the app target assigns at window
    /// creation. Exposed so app-target call sites that still speak bare `UUID`
    /// can bridge across the seam without a second identifier space.
    public let rawValue: UUID

    /// Wraps an existing window `UUID` as a typed ``WindowID``.
    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

extension WindowID: CustomStringConvertible {
    /// The first eight characters of the underlying UUID, matching the app's
    /// existing debug-log window-id formatting.
    public var description: String {
        String(rawValue.uuidString.prefix(8))
    }
}
