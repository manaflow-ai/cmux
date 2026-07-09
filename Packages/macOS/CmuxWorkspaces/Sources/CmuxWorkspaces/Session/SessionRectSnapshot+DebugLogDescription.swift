#if DEBUG
import Foundation

extension SessionRectSnapshot {
    /// A compact one-line description of the rect for session-save/restore debug
    /// logs, e.g. `x=10.0 y=20.0 w=800.0 h=600.0`. Each component is rendered to
    /// one decimal place. The legacy `nil` rendering lives at the call site as
    /// `rect?.debugLogDescription ?? "nil"`.
    public var debugLogDescription: String {
        "x=\(Self.debugNumber(x)) y=\(Self.debugNumber(y)) " +
            "w=\(Self.debugNumber(width)) h=\(Self.debugNumber(height))"
    }

    /// Formats a coordinate to one decimal place, matching the legacy
    /// `String(format: "%.1f", value)` rendering of session geometry logs.
    private static func debugNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
#endif
