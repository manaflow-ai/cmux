/// Builds the diagnostic context for a CLI socket error.
///
/// Operation telemetry can describe an earlier attempt. Typed values from the
/// error that is being captured are therefore applied last and remain
/// authoritative.
public struct CLISocketErrorTelemetryContext {
    /// Creates a telemetry-context merger.
    public init() {}

    /// Combines base, operation, and typed error metadata in precedence order.
    ///
    /// - Parameters:
    ///   - base: Metadata shared by every CLI socket report.
    ///   - operation: Metadata from the current socket operation.
    ///   - error: Captured error whose typed fields take precedence.
    /// - Returns: The merged diagnostic context.
    public func merging(
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
