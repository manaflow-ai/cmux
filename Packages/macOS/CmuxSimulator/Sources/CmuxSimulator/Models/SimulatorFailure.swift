/// A process-safe failure reported by Simulator discovery, control, or rendering.
public struct SimulatorFailure: Error, Codable, Equatable, Sendable {
    /// A stable machine-readable failure code.
    public let code: String
    /// A concise diagnostic message for logs. UI maps ``code`` to localized copy.
    public let message: String
    /// Whether retrying after an external state change can succeed.
    public let isRecoverable: Bool

    /// Creates a Simulator failure.
    public init(code: String, message: String, isRecoverable: Bool) {
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}
