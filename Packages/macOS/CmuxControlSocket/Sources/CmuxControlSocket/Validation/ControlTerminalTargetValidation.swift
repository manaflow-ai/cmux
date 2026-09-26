import Foundation

/// Pure validation for terminal target selector parameters shared by socket handlers.
public struct ControlTerminalTargetValidation: Sendable {
    /// Creates a validator for terminal target selectors.
    public init() {}

    /// Returns true when a request uses the unsupported `surface` selector.
    public func hasUnsupportedSurfaceParameter(_ params: [String: Any]) -> Bool {
        params.keys.contains("surface")
    }
}
