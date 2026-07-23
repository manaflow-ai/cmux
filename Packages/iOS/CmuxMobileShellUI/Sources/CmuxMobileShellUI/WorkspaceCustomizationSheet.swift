import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One editor for the durable identity of a workspace on its owning Mac.
struct WorkspaceCustomizationSheet: View {
    @State private var initialDraft: WorkspaceCustomizationDraft
    private let save: @MainActor (
        WorkspaceCustomizationDraft,
        WorkspaceCustomizationDraft
    ) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var customDescription: String
    @State private var usesCustomColor: Bool
    @State private var customColor: Color
    @State private var isPinned: Bool
    @State private var saveTask: Task<Void, Never>?

    init(
        workspace: MobileWorkspacePreview,
        save: @escaping @MainActor (
            WorkspaceCustomizationDraft,
            WorkspaceCustomizationDraft
        ) async -> Bool
    ) {
        let draft = WorkspaceCustomizationDraft(workspace: workspace)
        _initialDraft = State(initialValue: draft)
        self.save = save
        _name = State(initialValue: workspace.name)
        _customDescription = State(initialValue: workspace.customDescription ?? "")
        _usesCustomColor = State(initialValue: workspace.customColorHex != nil)
        _customColor = State(
            initialValue: workspace.customColorHex.flatMap { Color(hexString: $0) } ?? .blue
        )
        _isPinned = State(initialValue: workspace.isPinned)
    }

    var body: some View {
        NavigationStack {
            Form {
                identitySection
                descriptionSection
                appearanceSection
            }
            .disabled(saveTask != nil)
            .accessibilityIdentifier("MobileWorkspaceCustomizationForm")
            .accessibilityActions {
                if canSave {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        submit()
                    }
                }
            }
            .navigationTitle(
                L10n.string("mobile.workspace.customize.title", defaultValue: "Customize Workspace")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                    .disabled(saveTask != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        submit()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("MobileWorkspaceCustomizeSaveButton")
                }
            }
        }
        .interactiveDismissDisabled(saveTask != nil)
        .onDisappear {
            saveTask?.cancel()
            saveTask = nil
        }
    }

    private var identitySection: some View {
        Section(
            L10n.string("mobile.workspace.customize.identity", defaultValue: "Identity")
        ) {
            TextField(
                L10n.string("mobile.workspace.customize.name", defaultValue: "Name"),
                text: $name
            )
            .textInputAutocapitalization(.sentences)
            .submitLabel(.done)
            .accessibilityIdentifier("MobileWorkspaceNameField")

            Toggle(
                L10n.string("mobile.workspace.customize.pinned", defaultValue: "Pinned"),
                isOn: $isPinned
            )
            .accessibilityIdentifier("MobileWorkspacePinnedToggle")
        }
    }

    private var descriptionSection: some View {
        Section {
            TextField(
                L10n.string(
                    "mobile.workspace.customize.description.placeholder",
                    defaultValue: "What is this workspace for?"
                ),
                text: $customDescription,
                axis: .vertical
            )
            .lineLimit(3...8)
            .accessibilityIdentifier("MobileWorkspaceDescriptionField")
        } header: {
            Text(L10n.string("mobile.workspace.customize.description", defaultValue: "Description"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    L10n.string(
                        "mobile.workspace.customize.description.help",
                        defaultValue: "Shown in the workspace list above live activity."
                    )
                )
            }
        }
    }

    private var appearanceSection: some View {
        Section(
            L10n.string("mobile.workspace.customize.appearance", defaultValue: "Appearance")
        ) {
            Toggle(
                L10n.string(
                    "mobile.workspace.customize.useColor",
                    defaultValue: "Use Workspace Color"
                ),
                isOn: $usesCustomColor
            )
            .accessibilityIdentifier("MobileWorkspaceColorToggle")

            if usesCustomColor {
                ColorPicker(
                    L10n.string("mobile.workspace.customize.color", defaultValue: "Color"),
                    selection: $customColor,
                    supportsOpacity: false
                )
                .accessibilityIdentifier("MobileWorkspaceColorPicker")
            }
        }
    }

    private var draft: WorkspaceCustomizationDraft {
        WorkspaceCustomizationDraft(
            name: name,
            customDescription: customDescription,
            customColorHex: usesCustomColor ? customColor.hexString : nil,
            isPinned: isPinned
        )
    }

    private var canSave: Bool {
        saveTask == nil
            && !draft.name.isEmpty
            && (!usesCustomColor || customColor.hexString != nil)
            && draft != initialDraft
    }

    private func submit() {
        guard saveTask == nil else { return }
        let submittedDraft = draft
        saveTask = Task { @MainActor in
            let succeeded = await save(initialDraft, submittedDraft)
            guard !Task.isCancelled else { return }
            saveTask = nil
            if succeeded {
                dismiss()
            }
        }
    }
}
