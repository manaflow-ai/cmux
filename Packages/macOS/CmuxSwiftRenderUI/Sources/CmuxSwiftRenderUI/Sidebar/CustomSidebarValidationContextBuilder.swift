import CmuxSidebar
import CmuxSwiftRender
import Foundation

/// Builds deterministic runtime-shaped contexts for custom-sidebar validation.
struct CustomSidebarValidationContextBuilder {
    private let runtimeBuilder: CustomSidebarDataContextBuilder

    /// Creates a validation builder around the production context builder.
    init(calendar: Calendar) {
        self.runtimeBuilder = CustomSidebarDataContextBuilder(calendar: calendar)
    }

    /// Builds rich and optional-data-free contexts plus the fields that differ.
    func representativeContexts() -> (
        rich: [String: SwiftValue],
        withoutOptionalData: [String: SwiftValue],
        changedWorkspaceFields: Set<String>
    ) {
        let richWorkspace = representativeSelectedWorkspace(
            includingOptionalData: true
        )
        let comparisonWorkspace = representativeSelectedWorkspace(
            includingOptionalData: false
        )
        let sparseWorkspace = representativeSparseWorkspace()
        let rich = runtimeBuilder.dataContext(
            for: representativeSnapshot(
                workspaces: [sparseWorkspace, richWorkspace]
            )
        )
        let withoutOptionalData = runtimeBuilder.dataContext(
            for: representativeSnapshot(
                workspaces: [sparseWorkspace, comparisonWorkspace]
            )
        )
        return (
            rich: rich,
            withoutOptionalData: withoutOptionalData,
            changedWorkspaceFields: changedFieldNames(
                between: selectedWorkspaceFields(in: rich),
                and: selectedWorkspaceFields(in: withoutOptionalData)
            )
        )
    }

    /// Builds the selected representative workspace with or without optional data.
    private func representativeSelectedWorkspace(
        includingOptionalData: Bool
    ) -> CustomSidebarWorkspaceSnapshot {
        let pullRequest: SwiftValue = .object([
            "number": .int(412),
            "label": .string("PR #412"),
            "url": .string("https://github.com/manaflow-ai/cmux/pull/412"),
            "status": .string("open"),
            "stale": .bool(false),
            "branch": .string("fix/checkout"),
        ])
        return CustomSidebarWorkspaceSnapshot(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0x04, 0x12
                )
            ),
            title: "checkout-flow",
            isSelected: true,
            isPinned: false,
            index: 0,
            directory: "/Users/cmux/checkout-flow",
            listeningPorts: [3000],
            unreadCount: 3,
            surfaces: [
                CustomSidebarSurfaceSnapshot(
                    panelId: UUID(
                        uuid: (
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0x04, 0x14
                        )
                    ),
                    title: "Tests",
                    isFocused: true,
                    isPinned: false,
                    directory: "/Users/cmux/checkout-flow",
                    gitBranch: "fix/checkout",
                    gitIsDirty: false,
                    listeningPorts: [3000]
                )
            ],
            surfaceCount: 1,
            customDescription: includingOptionalData ? "Checkout work" : nil,
            customColor: includingOptionalData ? "#7AA2F7" : nil,
            gitBranch: includingOptionalData ? "fix/checkout" : nil,
            gitIsDirty: false,
            pullRequestValues: includingOptionalData ? [pullRequest] : [],
            progress: includingOptionalData
                ? .init(value: 0.41, label: "Tests running")
                : nil,
            latestConversationMessage: includingOptionalData
                ? "Waiting for review"
                : nil,
            latestSubmittedMessage: includingOptionalData
                ? "Finish checkout coverage"
                : nil,
            latestSubmittedAt: includingOptionalData
                ? Date(timeIntervalSince1970: 1_779_999_400)
                : nil,
            remote: includingOptionalData
                ? .init(
                    target: "aws-m4pro-1",
                    stateRawValue: "connected",
                    isConnected: true
                )
                : nil
        )
    }

    /// Builds an unselected workspace whose optional runtime fields are absent.
    private func representativeSparseWorkspace()
        -> CustomSidebarWorkspaceSnapshot
    {
        CustomSidebarWorkspaceSnapshot(
            id: UUID(
                uuid: (
                    0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0x04, 0x13
                )
            ),
            title: "notes",
            isSelected: false,
            isPinned: false,
            index: 1,
            directory: "/Users/cmux/notes",
            listeningPorts: [],
            unreadCount: 0,
            surfaces: [],
            surfaceCount: 0,
            customDescription: nil,
            customColor: nil,
            gitBranch: nil,
            gitIsDirty: false,
            pullRequestValues: [],
            progress: nil,
            latestConversationMessage: nil,
            latestSubmittedMessage: nil,
            latestSubmittedAt: nil,
            remote: nil
        )
    }

    /// Builds a deterministic runtime snapshot around representative workspaces.
    private func representativeSnapshot(
        workspaces: [CustomSidebarWorkspaceSnapshot]
    ) -> CustomSidebarContextSnapshot {
        let selectedId = UUID(
            uuid: (
                0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0x04, 0x12
            )
        )
        return CustomSidebarContextSnapshot(
            workspaces: workspaces,
            selectedWorkspaceId: selectedId,
            selectedWorkspaceTitle: "checkout-flow",
            totalUnreadCount: 3,
            now: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    /// Extracts fields from the selected runtime workspace.
    private func selectedWorkspaceFields(
        in context: [String: SwiftValue]
    ) -> [String: SwiftValue] {
        guard case let .string(selectedId)? = context["selectedId"],
            case let .array(workspaces)? = context["workspaces"],
            case let .object(fields)? = workspaces.first(where: {
                guard case let .object(fields) = $0 else { return false }
                return fields["id"] == .string(selectedId)
            })
        else {
            return [:]
        }
        return fields
    }

    /// Returns fields whose representative runtime values differ across contexts.
    private func changedFieldNames(
        between richFields: [String: SwiftValue],
        and comparisonFields: [String: SwiftValue]
    ) -> Set<String> {
        let fieldNames = Set(richFields.keys).union(comparisonFields.keys)
        return Set(
            fieldNames.filter {
                richFields[$0] != comparisonFields[$0]
            })
    }
}
