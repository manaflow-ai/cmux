public import Foundation

/// One harness this Mac's acpmux lists (`_acpmux/harnesses`, with `_acpmux/harness/health`'s
/// sign-in), as New Chief reads it: the input of ``HomeChiefHarnessChoice/choices(listed:)``.
public nonisolated struct HomeChiefListedHarness: Hashable, Sendable {
    /// The acpmux harness id (`claude`, `opencode`, a profile of the person's own).
    public var id: String
    /// The name acpmux gives it (its `displayName`), or the id.
    public var name: String
    /// acpmux's reason it cannot start (its launcher check failed); nil when it can.
    public var unavailable: String?
    /// The harness health check found it signed out.
    public var signedOut: Bool

    /// - Parameters:
    ///   - id: the acpmux harness id.
    ///   - name: its display name; the id when acpmux names none.
    ///   - unavailable: why its launcher check failed, if it did.
    ///   - signedOut: whether its health check found it signed out.
    public init(id: String, name: String, unavailable: String? = nil, signedOut: Bool = false) {
        self.id = id
        self.name = name
        self.unavailable = unavailable
        self.signedOut = signedOut
    }
}
