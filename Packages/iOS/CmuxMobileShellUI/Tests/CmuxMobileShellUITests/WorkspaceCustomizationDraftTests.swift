import CMUXMobileCore
import Testing
@testable import CmuxMobileShellUI

@Suite struct WorkspaceCustomizationDraftTests {
    @Test func descriptionNormalizesLineEndingsAndTrimsEdgeWhitespace() {
        let draft = WorkspaceCustomizationDraft(
            name: "Workspace",
            customDescription: "  Release\r\nvalidation  ",
            customColorHex: nil,
            isPinned: false
        )

        #expect(draft.customDescription == "Release\nvalidation")
    }

    @Test func descriptionBoundsUTF8Bytes() {
        let draft = WorkspaceCustomizationDraft(
            name: "Workspace",
            customDescription: String(repeating: "🧪", count: 2_000),
            customColorHex: nil,
            isPinned: false
        )

        #expect(
            draft.customDescription?.utf8.count
                == MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes
        )
    }

    @Test func rebasePreservesDirtyFieldsAndAppliesUntouchedFields() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Edited",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let authoritative = WorkspaceCustomizationDraft(
            name: "Concurrent rename",
            customDescription: "Concurrent description",
            customColorHex: "#222222",
            isPinned: true
        )

        let rebased = submitted.rebasingUntouchedFields(
            from: authoritative,
            comparedTo: initial
        )

        #expect(rebased.name == "Edited")
        #expect(rebased.customDescription == "Concurrent description")
        #expect(rebased.customColorHex == "#222222")
        #expect(rebased.isPinned)
    }

    @Test func rebaseCarriesAuthoritativeDescriptionTruncationForUntouchedDescription() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Mobile-safe prefix",
            customDescriptionIsTruncated: false,
            customColorHex: nil,
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Edited",
            customDescription: "Mobile-safe prefix",
            customDescriptionIsTruncated: false,
            customColorHex: nil,
            isPinned: false
        )
        let authoritative = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Mobile-safe prefix",
            customDescriptionIsTruncated: true,
            customColorHex: nil,
            isPinned: false
        )

        let rebased = submitted.rebasingUntouchedFields(
            from: authoritative,
            comparedTo: initial
        )

        #expect(rebased.name == "Edited")
        #expect(rebased.customDescription == "Mobile-safe prefix")
        #expect(rebased.customDescriptionIsTruncated)
    }

    @Test func mutationDecisionAppliesWhenAuthoritativeStillMatchesInitial() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#222222",
            isPinned: false
        )

        #expect(initial.mutationDecision(
            submitted: submitted,
            authoritative: initial,
            field: \.customColorHex
        ) == .apply)
    }

    @Test func mutationDecisionSkipsWhenAuthoritativeAlreadyMatchesSubmitted() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#222222",
            isPinned: false
        )

        #expect(initial.mutationDecision(
            submitted: submitted,
            authoritative: submitted,
            field: \.customColorHex
        ) == .none)
    }

    @Test func mutationDecisionConflictsWhenAuthoritativeDivergesFromInitialAndSubmitted() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#222222",
            isPinned: false
        )
        let authoritative = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: nil,
            customColorHex: "#333333",
            isPinned: false
        )

        #expect(initial.mutationDecision(
            submitted: submitted,
            authoritative: authoritative,
            field: \.customColorHex
        ) == .conflict)
    }

    @Test func rebaseKeepsFailedDirtyFieldsRetryableAfterPartialSuccess() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Renamed",
            customDescription: "Pending description",
            customColorHex: "#222222",
            isPinned: true
        )
        let authoritativeAfterDescriptionFailure = WorkspaceCustomizationDraft(
            name: "Renamed",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )

        let rebased = submitted.rebasingUntouchedFields(
            from: authoritativeAfterDescriptionFailure,
            comparedTo: initial
        )

        #expect(rebased.name == "Renamed")
        #expect(rebased.customDescription == "Pending description")
        #expect(rebased.customColorHex == "#222222")
        #expect(rebased.isPinned)
    }

    @Test func retryDisplayStaysDirtyAgainstAuthoritativeBaselineAfterPartialFailure() {
        let initial = WorkspaceCustomizationDraft(
            name: "Original",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )
        let submitted = WorkspaceCustomizationDraft(
            name: "Renamed",
            customDescription: "Pending description",
            customColorHex: "#222222",
            isPinned: true
        )
        let authoritativeAfterDescriptionFailure = WorkspaceCustomizationDraft(
            name: "Renamed",
            customDescription: "Old description",
            customColorHex: "#111111",
            isPinned: false
        )

        let retryDisplay = submitted.rebasingUntouchedFields(
            from: authoritativeAfterDescriptionFailure,
            comparedTo: initial
        )
        let dirtyFields = retryDisplay.dirtyFields(
            comparedTo: authoritativeAfterDescriptionFailure
        )

        #expect(!dirtyFields.name)
        #expect(dirtyFields.customDescription)
        #expect(dirtyFields.customColorHex)
        #expect(dirtyFields.isPinned)
    }
}
