import Foundation

/// Shared v2-payload output helpers used across the CLI's namespaces.
/// Extracted from `CLI/cmux.swift`, which sits at its file-length budget.
extension CMUXCLI {
    /// Formats a `<kind>_id` / `<kind>_ref` handle pair from a v2 payload
    /// according to the requested id format.
    func formatHandle(_ payload: [String: Any], kind: String, idFormat: CLIIDFormat) -> String? {
        let id = payload["\(kind)_id"] as? String
        let ref = payload["\(kind)_ref"] as? String
        switch idFormat {
        case .refs:
            return ref ?? id
        case .uuids:
            return id ?? ref
        case .both:
            if let ref, let id {
                return "\(ref) (\(id))"
            }
            return ref ?? id
        }
    }

    /// Prints a v2 payload: the id-formatted JSON when `--json` was given,
    /// otherwise the human-readable fallback text.
    func printV2Payload(
        _ payload: [String: Any],
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        fallbackText: String
    ) {
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
        } else {
            print(fallbackText)
        }
    }
}
