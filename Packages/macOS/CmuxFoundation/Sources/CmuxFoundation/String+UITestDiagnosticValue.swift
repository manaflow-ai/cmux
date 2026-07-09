import Foundation

public extension String {
    /// A diagnostic string for an arbitrary value emitted into the UI-test diagnostics dictionary.
    ///
    /// Coerces a heterogeneous `Any?` (the values pulled from the portal-stats dictionary) into the
    /// stable string spelling the UI tests expect: booleans become `"1"`/`"0"`, `Int` and `NSNumber`
    /// use their decimal description, `UUID` uses `uuidString`, any other non-nil value falls back to
    /// `String(describing:)`, and `nil` becomes the empty string.
    ///
    /// - Parameter value: The value to describe, or `nil`.
    init(uiTestDiagnosticDescribing value: Any?) {
        switch value {
        case let value as String:
            self = value
        case let value as Bool:
            self = value ? "1" : "0"
        case let value as Int:
            self = String(value)
        case let value as NSNumber:
            self = value.stringValue
        case let value as UUID:
            self = value.uuidString
        case .some(let value):
            self = String(describing: value)
        case .none:
            self = ""
        }
    }
}
