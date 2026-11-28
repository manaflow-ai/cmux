import Foundation

extension DaemonError {
    /// The daemon does not have the `cmux.protocol/2` operation: an older cmux-tui answers one
    /// it does not know as an invalid envelope (`validation.invalid`, serde's "unknown variant").
    /// A refusal of the request's values has the same code but no unknown variant.
    public var isUnknownOperation: Bool {
        guard case .command(_, _, let code, let details, _) = self, code == "validation.invalid",
              case .object(let fields)? = details, let error = fields["error"]?.stringValue else { return false }
        return error.contains("unknown variant")
    }
}
