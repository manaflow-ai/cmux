#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Lets the task composer choose a new workspace or a pane from an existing
/// workspace. Pane rectangles are drawn from the Mac's normalized topology.
struct TaskComposerDestinationPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .caption2) private var minimumPaneHeight: CGFloat = 52

    /// Keep the picker compact until the user chooses which workspace to
    /// inspect. Only one workspace can be expanded at a time so the pane maps
    /// remain easy to compare on a phone.
    @State private var expandedWorkspaceID: MobileWorkspacePreview.ID?

    let workspaces: [MobileWorkspacePreview]
    let selectedWorkspaceID: MobileWorkspacePreview.ID?
    let selectedPaneID: MobilePanePreview.ID?
    let workspaceGroups: [MobileWorkspaceGroupPreview]
    let selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?
    let workspaceGroupSelectionPending: Bool
    let workspaceGroupSelectionRequiresResolution: Bool
    let showsWorkspaceGroupPicker: Bool
    let isDisabled: Bool
    let select: (MobileWorkspacePreview.ID?, MobilePanePreview.ID?) -> Void
    let selectWorkspaceGroup: (MobileWorkspaceGroupPreview.ID?) -> Void

    init(
        workspaces: [MobileWorkspacePreview],
        selectedWorkspaceID: MobileWorkspacePreview.ID?,
        selectedPaneID: MobilePanePreview.ID?,
        workspaceGroups: [MobileWorkspaceGroupPreview],
        selectedWorkspaceGroupID: MobileWorkspaceGroupPreview.ID?,
        workspaceGroupSelectionPending: Bool,
        workspaceGroupSelectionRequiresResolution: Bool,
        showsWorkspaceGroupPicker: Bool,
        isDisabled: Bool,
        select: @escaping (MobileWorkspacePreview.ID?, MobilePanePreview.ID?) -> Void,
        selectWorkspaceGroup: @escaping (MobileWorkspaceGroupPreview.ID?) -> Void
    ) {
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.selectedPaneID = selectedPaneID
        self.workspaceGroups = workspaceGroups
        self.selectedWorkspaceGroupID = selectedWorkspaceGroupID
        self.workspaceGroupSelectionPending = workspaceGroupSelectionPending
        self.workspaceGroupSelectionRequiresResolution = workspaceGroupSelectionRequiresResolution
        self.showsWorkspaceGroupPicker = showsWorkspaceGroupPicker
        self.isDisabled = isDisabled
        self.select = select
        self.selectWorkspaceGroup = selectWorkspaceGroup
        _expandedWorkspaceID = State(
            initialValue: selectedPaneID == nil ? nil : selectedWorkspaceID
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    newWorkspaceCard

                    if workspaces.isEmpty {
                        Text(L10n.string(
                            "mobile.taskComposer.destination.noPanes",
                            defaultValue: "No existing panes are available on this Mac."
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    } else {
                        ForEach(workspaces) { workspace in
                            workspaceCard(workspace)
                        }
                    }
                }
                .padding(20)
            }
            .background {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            }
            .navigationTitle(L10n.string(
                "mobile.taskComposer.destination.title",
                defaultValue: "Run task in"
            ))
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("MobileTaskComposerDestinationDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var isNewWorkspaceSelected: Bool {
        selectedWorkspaceID == nil && selectedPaneID == nil
    }

    private var newWorkspaceCard: some View {
        VStack(spacing: 0) {
            Button {
                select(nil, nil)
                expandedWorkspaceID = nil
            } label: {
                destinationRow(
                    icon: "plus.square",
                    title: L10n.string(
                        "mobile.taskComposer.destination.newWorkspace",
                        defaultValue: "New workspace"
                    ),
                    subtitle: L10n.string(
                        "mobile.taskComposer.destination.newWorkspace.detail",
                        defaultValue: "Start the task in a new workspace"
                    ),
                    isSelected: isNewWorkspaceSelected
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityAddTraits(isNewWorkspaceSelected ? .isSelected : [])
            .accessibilityIdentifier("MobileTaskComposerDestinationNewWorkspace")

            if showsWorkspaceGroupPicker {
                Divider()
                    .padding(.leading, 58)

                TaskComposerWorkspaceGroupMenu(
                    groups: workspaceGroups,
                    selectedWorkspaceGroupID: selectedWorkspaceGroupID,
                    isSelectionPending: workspaceGroupSelectionPending,
                    requiresSelectionResolution: workspaceGroupSelectionRequiresResolution,
                    isDisabled: isDisabled || !isNewWorkspaceSelected,
                    select: selectWorkspaceGroup
                )
                .padding(.vertical, 4)
                .opacity(isNewWorkspaceSelected ? 1 : 0.5)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func workspaceCard(_ workspace: MobileWorkspacePreview) -> some View {
        DisclosureGroup(
            isExpanded: expandedBinding(for: workspace.rpcWorkspaceID)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string(
                    "mobile.taskComposer.destination.choosePane",
                    defaultValue: "Choose a pane"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                paneMap(for: workspace)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.title3)
                    .foregroundStyle(.tint)
                Text(workspace.name)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
            }
        }
        .accessibilityIdentifier(
            "MobileTaskComposerDestinationWorkspace-\(workspace.rpcWorkspaceID.rawValue)"
        )
        .disabled(isDisabled)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func expandedBinding(
        for workspaceID: MobileWorkspacePreview.ID
    ) -> Binding<Bool> {
        Binding(
            get: { expandedWorkspaceID == workspaceID },
            set: { isExpanded in
                expandedWorkspaceID = isExpanded ? workspaceID : nil
            }
        )
    }

    private func paneMap(for workspace: MobileWorkspacePreview) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))

                ForEach(workspace.panes) { pane in
                    let frame = pane.frame
                    let paneGap: CGFloat = 4
                    let paneWidth = max(44, proxy.size.width * frame.width - paneGap)
                    let paneHeight = proxy.size.height * frame.height - paneGap
                    Button {
                        select(workspace.rpcWorkspaceID, pane.id)
                        dismiss()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: pane.isFocused ? "scope" : "rectangle")
                                .font(.caption2)
                            Text(surfaceTitle(for: pane, workspace: workspace))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            pane.id == selectedPaneID && workspace.rpcWorkspaceID == selectedWorkspaceID
                                ? Color.accentColor.opacity(0.28)
                                : Color(uiColor: .systemBackground).opacity(0.72),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(
                                    pane.id == selectedPaneID && workspace.rpcWorkspaceID == selectedWorkspaceID
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.25),
                                    lineWidth: pane.id == selectedPaneID && workspace.rpcWorkspaceID == selectedWorkspaceID ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityIdentifier(
                        "MobileTaskComposerDestinationPane-\(workspace.rpcWorkspaceID.rawValue)-\(pane.id.rawValue)"
                    )
                    .frame(
                        width: paneWidth,
                        height: paneHeight
                    )
                    .offset(
                        x: proxy.size.width * frame.x + paneGap / 2,
                        y: proxy.size.height * frame.y + paneGap / 2
                    )
                }
            }
        }
        .frame(height: paneMapHeight(for: workspace))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(workspace.name)
    }

    private func paneMapHeight(for workspace: MobileWorkspacePreview) -> CGFloat {
        let smallestPaneHeight = workspace.panes.map(\.frame.height).filter { $0 > 0 }.min() ?? 1
        // Grow the whole map so shallow panes retain padding and useful tap
        // targets without overlapping their neighbors or changing split ratios.
        return max(160, (minimumPaneHeight + 4) / smallestPaneHeight)
    }

    private func surfaceTitle(
        for pane: MobilePanePreview,
        workspace: MobileWorkspacePreview
    ) -> String {
        guard let selectedSurfaceID = pane.selectedSurfaceID,
              let surface = workspace.surfaces.first(where: { $0.id == selectedSurfaceID }) else {
            return L10n.string("mobile.taskComposer.destination.pane", defaultValue: "Pane")
        }
        return surface.title
    }

    private func destinationRow(
        icon: String,
        title: String,
        subtitle: String,
        isSelected: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
        .padding(14)
    }
}
#endif
