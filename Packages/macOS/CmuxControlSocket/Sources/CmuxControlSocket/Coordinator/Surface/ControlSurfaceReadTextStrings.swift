public import Foundation

/// The app-bundle-resolved localized strings for `surface.read_text`.
///
/// They MUST resolve in the app conformance (app bundle), not the package: inside
/// the package `String(localized:)` binds to the package bundle, which lacks the
/// keys and silently drops translations. The app resolves each with the identical
/// key + defaultValue and passes them through.
public struct ControlSurfaceReadTextStrings: Sendable, Equatable {
    /// `rpc.v2.surface.read_text.linesMustBeGreaterThanZero` — "lines must be
    /// greater than 0".
    public let linesMustBeGreaterThanZero: String

    /// Creates the read-text strings.
    ///
    /// - Parameter linesMustBeGreaterThanZero: The invalid non-positive `lines`
    ///   parameter message.
    public init(linesMustBeGreaterThanZero: String) {
        self.linesMustBeGreaterThanZero = linesMustBeGreaterThanZero
    }
}
