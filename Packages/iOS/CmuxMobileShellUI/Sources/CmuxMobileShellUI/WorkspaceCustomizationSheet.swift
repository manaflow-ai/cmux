import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One editor for the durable identity of a workspace on its owning Mac.
struct WorkspaceCustomizationSheet: View {
    private let initialDraft: WorkspaceCustomizationDraft
    private let save: (WorkspaceCustomizationDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var customDescription: String
    @State private var usesCustomColor: Bool
    @State private var customColor: Color
    @State private var isPinned: Bool

    init(
        workspace: MobileWorkspacePreview,
        save: @escaping (WorkspaceCustomizationDraft) -> Void
    ) {
        let draft = WorkspaceCustomizationDraft(workspace: workspace)
        initialDraft = draft
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
            .navigationTitle(
                L10n.string("mobile.workspace.customize.title", defaultValue: "Customize Workspace")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.common.save", defaultValue: "Save")) {
                        save(draft)
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("MobileWorkspaceCustomizeSaveButton")
                }
            }
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
        !draft.name.isEmpty
            && (!usesCustomColor || customColor.hexString != nil)
            && draft != initialDraft
    }
}
