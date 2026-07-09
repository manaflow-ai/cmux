public import Foundation

/// Pure value logic for the `NSWindow.identifier` raw values that address cmux
/// main terminal windows.
///
/// A main terminal window's identifier is `"cmux.main.<windowId-uuid>"`; the
/// legacy/primary window used the bare `"cmux.main"`. This value type owns both
/// the expected-identifier construction for a specific window id and the
/// class-level predicate that recognizes any main terminal window identifier,
/// so the string contract lives in exactly one place rather than being inlined
/// at every `NSApp.windows` scan and `isMainTerminalWindow` gate.
public struct MainTerminalWindowIdentifier: Sendable, Equatable, Hashable {
    /// The window id this identifier addresses.
    public let windowId: UUID

    /// Creates the identifier value for `windowId`.
    public init(forWindowId windowId: UUID) {
        self.windowId = windowId
    }

    /// The `NSWindow.identifier` raw value addressing this specific main
    /// terminal window, e.g. `"cmux.main.<uuid>"`.
    public var expectedIdentifier: String {
        "cmux.main.\(windowId.uuidString)"
    }

    /// True when `rawIdentifier` denotes any main terminal window: the bare
    /// `"cmux.main"` primary identifier or any `"cmux.main."`-prefixed
    /// per-window identifier.
    public static func matches(rawIdentifier: String) -> Bool {
        rawIdentifier == "cmux.main" || rawIdentifier.hasPrefix("cmux.main.")
    }
}
