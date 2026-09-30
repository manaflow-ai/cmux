import CmuxCloud
import Foundation

/// The name shown in the machine Rename prompt. ``MachineSnapshot.displayName``
/// is the row's authoritative label, but it falls back to the provider id when
/// no label or slug is available. An opaque id is useful for routing and must
/// stay out of this human-facing prompt.
enum CloudMachineRenamePresentation {
    static func promptName(for machine: MachineSnapshot) -> String {
        let displayName = machine.displayName
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHumanName = [machine.label, machine.slug].contains { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !trimmedDisplayName.isEmpty, hasHumanName else {
            return String(localized: "machines.rename.fallbackName", defaultValue: "Cloud machine")
        }
        return displayName
    }
}
