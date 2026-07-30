import CmuxControlSocket

/// A recoverable UI automation failure with machine-readable recovery data.
public struct SimulatorUIAutomationFailure: Error, Sendable {
    /// Stable control-socket failure code.
    public let code: String
    /// Localized user-facing failure message.
    public let message: String
    /// Structured UI automation recovery data.
    public let uiError: JSONValue

    /// Creates a structured UI automation failure.
    public init(
        code: String,
        message: String,
        recoveryHint: String,
        elementRef: String? = nil,
        candidates: [JSONValue] = [],
        snapshotAgeMilliseconds: Int64? = nil,
        timeoutMilliseconds: Int? = nil
    ) {
        self.code = code
        self.message = message
        var fields: [String: JSONValue] = [
            "code": .string(code.uppercased()),
            "message": .string(message),
            "recovery_hint": .string(recoveryHint),
        ]
        if let elementRef {
            fields["element_ref"] = .string(elementRef)
        }
        if !candidates.isEmpty {
            fields["candidates"] = .array(candidates)
        }
        if let snapshotAgeMilliseconds {
            fields["snapshot_age_milliseconds"] = .int(snapshotAgeMilliseconds)
        }
        if let timeoutMilliseconds {
            fields["timeout_milliseconds"] = .int(Int64(timeoutMilliseconds))
        }
        uiError = .object(fields)
    }

    /// Control-socket payload containing the structured failure.
    public var controlData: JSONValue {
        .object(["ui_error": uiError])
    }
}
