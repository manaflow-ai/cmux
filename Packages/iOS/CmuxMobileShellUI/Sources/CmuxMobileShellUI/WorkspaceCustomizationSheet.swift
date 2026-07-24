import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One editor for the durable identity of a workspace on its owning Mac.
struct WorkspaceCustomizationSheet: View {
    @State private var initialDraft: WorkspaceCustomizationDraft
    private let save: @MainActor (
        WorkspaceCustomizationDraft,
        WorkspaceCustomizationDraft
    ) async -> WorkspaceCustomizationSaveResult
    private let descriptionIsTruncated: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var customDescription: String
    @State private var usesCustomColor: Bool
    @State private var customColor: Color
    @State private var isPinned: Bool
    @State private var saveTask: Task<Void, Never>?
    @State private var saveFailure: WorkspaceCustomizationSaveFailure?

    init(
        workspace: MobileWorkspacePreview,
        save: @escaping @MainActor (
            WorkspaceCustomizationDraft,
            WorkspaceCustomizationDraft
        ) async -> WorkspaceCustomizationSaveResult
    ) {
        let draft = WorkspaceCustomizationDraft(workspace: workspace)
        _initialDraft = State(initialValue: draft)
        self.save = save
        self.descriptionIsTruncated = workspace.customDescriptionIsTruncated
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
        .alert(
            saveFailure?.title ?? "",
            isPresented: Binding(
                get: { saveFailure != nil },
                set: { isPresented in
                    if !isPresented {
                        saveFailure = nil
                    }
                }
            )
        ) {
            Button(L10n.string("mobile.common.ok", defaultValue: "OK"), role: .cancel) {
                saveFailure = nil
            }
        } message: {
            if let message = saveFailure?.message {
                Text(message)
            }
        }
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
            .disabled(descriptionIsTruncated)
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
                if descriptionExceedsLimit {
                    Text(
                        L10n.string(
                            "mobile.workspace.customize.description.tooLong",
                            defaultValue: "Description must be 4 KB or less."
                        )
                    )
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("MobileWorkspaceDescriptionTooLong")
                }
                if descriptionIsTruncated {
                    Text(
                        L10n.string(
                            "mobile.workspace.customize.description.truncated",
                            defaultValue: "This Mac description is longer than iPhone can edit. Change it on Mac to avoid losing text."
                        )
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("MobileWorkspaceDescriptionTruncated")
                }
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
            && !descriptionExceedsLimit
            && (!usesCustomColor || customColor.hexString != nil)
            && draft != initialDraft
    }

    private var descriptionExceedsLimit: Bool {
        normalizedDescriptionByteCount
            > MobileWorkspaceMetadataLimits.customDescriptionMaxUTF8Bytes
    }

    private var normalizedDescriptionByteCount: Int {
        let description = customDescription
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return description.utf8.count
    }

    private func submit() {
        guard saveTask == nil else { return }
        let submittedDraft = draft
        saveFailure = nil
        saveTask = Task { @MainActor in
            let result = await save(initialDraft, submittedDraft)
            guard !Task.isCancelled else { return }
            saveTask = nil
            if let rebasedDraft = result.rebasedDraft {
                applyRebasedDraft(rebasedDraft, submittedDraft: submittedDraft)
            }
            if result.succeeded {
                dismiss()
            } else {
                saveFailure = result.failure
            }
        }
    }

    private func applyRebasedDraft(
        _ rebasedDraft: WorkspaceCustomizationDraft,
        submittedDraft: WorkspaceCustomizationDraft
    ) {
        let displayDraft = submittedDraft.rebasingUntouchedFields(
            from: rebasedDraft,
            comparedTo: initialDraft
        )
        initialDraft = rebasedDraft
        name = displayDraft.name
        customDescription = displayDraft.customDescription ?? ""
        isPinned = displayDraft.isPinned
        usesCustomColor = displayDraft.customColorHex != nil
        customColor = displayDraft.customColorHex.flatMap { Color(hexString: $0) } ?? .blue
    }
}
