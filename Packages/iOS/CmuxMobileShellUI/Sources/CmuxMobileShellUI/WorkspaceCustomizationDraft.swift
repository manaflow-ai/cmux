import CMUXMobileCore
import CmuxMobileShellModel
import Foundation

/// Editable workspace identity values presented by ``WorkspaceCustomizationSheet``.
struct WorkspaceCustomizationDraft: Equatable {
    let name: String
    let customDescription: String?
    let customDescriptionIsTruncated: Bool
    let customColorHex: String?
    let isPinned: Bool

    /// Builds a normalized draft from editor values.
    init(
        name: String,
        customDescription: String?,
        customDescriptionIsTruncated: Bool = false,
        customColorHex: String?,
        isPinned: Bool
    ) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = customDescription?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.customDescription = MobileWorkspaceMetadataLimits.normalizedCustomDescription(description)
        self.customDescriptionIsTruncated = customDescriptionIsTruncated
        let color = customColorHex?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.customColorHex = color?.isEmpty == false ? color : nil
        self.isPinned = isPinned
    }

    /// Builds a draft from the Mac's authoritative workspace snapshot.
    init(workspace: MobileWorkspacePreview) {
        self.init(
            name: workspace.name,
            customDescription: workspace.customDescription,
            customDescriptionIsTruncated: workspace.customDescriptionIsTruncated,
            customColorHex: workspace.customColorHex,
            isPinned: workspace.isPinned
        )
    }

    func dirtyFields(comparedTo baseline: WorkspaceCustomizationDraft) -> WorkspaceCustomizationDirtyFields {
        WorkspaceCustomizationDirtyFields(
            name: name != baseline.name,
            customDescription: customDescription != baseline.customDescription,
            customColorHex: customColorHex != baseline.customColorHex,
            isPinned: isPinned != baseline.isPinned
        )
    }

    func rebasingUntouchedFields(
        from authoritativeDraft: WorkspaceCustomizationDraft,
        comparedTo baseline: WorkspaceCustomizationDraft
    ) -> WorkspaceCustomizationDraft {
        let dirtyFields = dirtyFields(comparedTo: baseline)
        return WorkspaceCustomizationDraft(
            name: dirtyFields.name ? name : authoritativeDraft.name,
            customDescription: dirtyFields.customDescription
                ? customDescription
                : authoritativeDraft.customDescription,
            customDescriptionIsTruncated: dirtyFields.customDescription
                ? false
                : authoritativeDraft.customDescriptionIsTruncated,
            customColorHex: dirtyFields.customColorHex
                ? customColorHex
                : authoritativeDraft.customColorHex,
            isPinned: dirtyFields.isPinned ? isPinned : authoritativeDraft.isPinned
        )
    }

    func mutationDecision<Value: Equatable>(
        submitted submittedDraft: WorkspaceCustomizationDraft,
        authoritative authoritativeDraft: WorkspaceCustomizationDraft,
        field: KeyPath<WorkspaceCustomizationDraft, Value>
    ) -> WorkspaceCustomizationFieldMutationDecision {
        let initialValue = self[keyPath: field]
        let submittedValue = submittedDraft[keyPath: field]
        guard initialValue != submittedValue else { return .none }

        let authoritativeValue = authoritativeDraft[keyPath: field]
        if authoritativeValue == submittedValue { return .none }
        guard authoritativeValue == initialValue else { return .conflict }
        return .apply
    }
}

struct WorkspaceCustomizationDirtyFields: Equatable {
    let name: Bool
    let customDescription: Bool
    let customColorHex: Bool
    let isPinned: Bool
}

enum WorkspaceCustomizationFieldMutationDecision: Equatable {
    case none
    case apply
    case conflict
}

struct WorkspaceCustomizationSaveFailure: Equatable {
    let title: String
    let message: String
}

struct WorkspaceCustomizationSaveResult: Equatable {
    let succeeded: Bool
    let rebasedDraft: WorkspaceCustomizationDraft?
    let displayDraft: WorkspaceCustomizationDraft?
    let failure: WorkspaceCustomizationSaveFailure?

    static let success = WorkspaceCustomizationSaveResult(
        succeeded: true,
        rebasedDraft: nil,
        displayDraft: nil,
        failure: nil
    )

    static func failure(
        rebasedTo rebasedDraft: WorkspaceCustomizationDraft? = nil,
        displaying displayDraft: WorkspaceCustomizationDraft? = nil,
        failure: WorkspaceCustomizationSaveFailure? = nil
    ) -> WorkspaceCustomizationSaveResult {
        WorkspaceCustomizationSaveResult(
            succeeded: false,
            rebasedDraft: rebasedDraft,
            displayDraft: displayDraft,
            failure: failure
        )
    }
}

typealias WorkspaceCustomizationAction = @MainActor (
    MobileWorkspacePreview.ID,
    WorkspaceCustomizationDraft,
    WorkspaceCustomizationDraft
) async -> WorkspaceCustomizationSaveResult
