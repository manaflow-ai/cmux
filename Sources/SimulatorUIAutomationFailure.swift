import CmuxControlSocket

/// A recoverable UI automation failure with machine-readable recovery data.
struct SimulatorUIAutomationFailure: Error, Sendable {
    let code: String
    let message: String
    let uiError: JSONValue

    init(
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

    var controlData: JSONValue {
        .object(["ui_error": uiError])
    }
}
