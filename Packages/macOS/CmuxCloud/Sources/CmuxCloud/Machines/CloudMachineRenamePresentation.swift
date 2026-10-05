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
        let displayName = machine.displayName
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHumanName = [machine.label, machine.slug].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !trimmedDisplayName.isEmpty, hasHumanName else { return fallbackName }
        return trimmedDisplayName
    }
}
