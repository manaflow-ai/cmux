/// The terminal result consumed by cmux sudo and cmux-sudo.
public struct SudoResult: Codable, Sendable, Equatable {
    /// The settled request identifier.
    public let id: String

    /// The terminal request status.
    public let status: SudoResultStatus

    /// The approved script's exit code, when it ran to completion.
    public let exitCode: Int32?

    /// The machine-readable failure reason, when available.
    public let errorCode: SudoResultErrorCode?

    /// A localized diagnostic suitable for the requesting terminal.
    public let note: String?

    /// Creates a terminal sudo result.
    ///
    /// - Parameters:
    ///   - id: The settled request identifier.
    ///   - status: The terminal request status.
    ///   - exitCode: The script exit code, if one exists.
    ///   - errorCode: A machine-readable failure reason.
    ///   - note: A localized diagnostic.
    public init(
        id: String,
        status: SudoResultStatus,
        exitCode: Int32? = nil,
        errorCode: SudoResultErrorCode? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.status = status
        self.exitCode = exitCode
        self.errorCode = errorCode
        self.note = note
    }
}
