import Foundation

/// Pure validation for terminal target selector parameters shared by socket handlers.
public enum ControlTerminalTargetValidation {
    /// Returns true when a request uses the unsupported `surface` selector.
    public static func hasUnsupportedSurfaceParameter(_ params: [String: Any]) -> Bool {
        params.keys.contains("surface")
    }
}
