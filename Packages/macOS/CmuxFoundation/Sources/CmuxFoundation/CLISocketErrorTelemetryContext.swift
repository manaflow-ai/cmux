/// Builds the diagnostic context for a CLI socket error.
///
/// Operation telemetry can describe an earlier attempt. Typed values from the
/// error that is being captured are therefore applied last and remain
/// authoritative.
public enum CLISocketErrorTelemetryContext {
    public static func merging(
        base: [String: Any],
        operation: [String: Any],
        error: any Error
    ) -> [String: Any] {
        var context = base
        for (key, value) in operation {
            context[key] = value
        }
        if let connectError = error as? CLISocketConnectError {
            for (key, value) in connectError.telemetryContext {
                context[key] = value
            }
        }
        return context
    }
}
