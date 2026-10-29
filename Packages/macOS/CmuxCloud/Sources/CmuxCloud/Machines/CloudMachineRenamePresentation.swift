import Foundation

/// Resolves the human-facing name used by a Cloud machine Rename prompt.
public struct CloudMachineRenamePresentation: Sendable {
    /// Creates a stateless machine rename presentation policy.
    public init() {}

    /// Returns a display label or a caller-provided localized fallback.
    ///
    /// - Parameters:
    ///   - machine: The immutable machine snapshot rendered by the Cloud row.
    ///   - fallbackName: Localized text used when the snapshot has no label or slug.
    /// - Returns: The label or generated slug when present, otherwise `fallbackName`.
    public func promptName(for machine: MachineSnapshot, fallbackName: String) -> String {
        if let label = machine.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return label
        }
        if let slug = machine.slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty {
            return slug
        }
        return fallbackName
    }
}
