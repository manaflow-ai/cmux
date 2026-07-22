import CmuxMobileShellModel
import Foundation

/// Editable workspace identity values presented by ``WorkspaceCustomizationSheet``.
struct WorkspaceCustomizationDraft: Equatable {
    let name: String
    let customDescription: String?
    let customColorHex: String?
    let isPinned: Bool

    /// Builds a normalized draft from editor values.
    init(name: String, customDescription: String?, customColorHex: String?, isPinned: Bool) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = customDescription?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let hasDescription = description?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        self.customDescription = hasDescription ? description : nil
        let color = customColorHex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.customColorHex = color?.isEmpty == false ? color : nil
        self.isPinned = isPinned
    }

    /// Builds a draft from the Mac's authoritative workspace snapshot.
    init(workspace: MobileWorkspacePreview) {
        self.init(
            name: workspace.name,
            customDescription: workspace.customDescription,
            customColorHex: workspace.customColorHex,
            isPinned: workspace.isPinned
        )
    }
}
