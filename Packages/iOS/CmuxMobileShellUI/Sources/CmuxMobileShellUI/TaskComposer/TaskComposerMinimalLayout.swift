#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// A full-screen prompt canvas with compact task controls above the keyboard.
struct TaskComposerMinimalLayout: View {
    @Binding var prompt: String
    let genericPromptPlaceholder: String
    let directory: String
    let isDisabled: Bool
    let locksDismissal: Bool
    let templates: [MobileTaskTemplate]
    let selectedTemplateID: MobileTaskTemplate.ID?
    let modelPickerVariant: TaskComposerModelPickerVariant
    let models: [MobileTaskAgentModel]
    let selectedModelID: String?
    let isSubmitting: Bool
    let isSubmitEnabled: Bool
    let failureTitle: String
    let failureText: String?
    let completedOperationRecovery: TaskComposerCompletedOperationRecovery?
    let optionsSheet: TaskComposerOptionsSheet
    let endEditing: () -> Void
    let selectTemplate: (MobileTaskTemplate.ID) -> Void
    let selectTemplateAndModel: (MobileTaskTemplate.ID, String?) -> Void
    let selectModel: (String?) -> Void
    let editTemplates: () -> Void
    let cancel: () -> Void
    let submit: () -> Void
    let refreshCompletedOperation: () -> Void
    let requestStartAgain: () -> Void

    @FocusState private var isPromptFocused: Bool
    @State private var isOptionsPresented = false

    var body: some View {
        promptCanvas
            .safeAreaInset(edge: .bottom, spacing: 0) {
                accessoryBar
            }
            .navigationTitle(navigationTitle)
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(locksDismissal)
                    .accessibilityLabel(L10n.string(
                        "mobile.common.cancel",
                        defaultValue: "Cancel"
                    ))
                    .accessibilityIdentifier("MobileTaskComposerCancelButton")
                }
            }
            .sheet(isPresented: $isOptionsPresented) {
                optionsSheet
            }
    }

    private var promptCanvas: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            if prompt.isEmpty {
                Text(promptPlaceholder)
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 27)
                    .padding(.horizontal, 25)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TextEditor(text: $prompt)
                .scrollContentBackground(.hidden)
                .font(.title3)
                .fontWeight(.regular)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .focused($isPromptFocused)
                .disabled(isDisabled)
                .scrollDismissesKeyboard(.interactively)
                .accessibilityLabel(L10n.string(
                    "mobile.taskComposer.prompt",
                    defaultValue: "Prompt"
                ))
                .accessibilityHint(promptPlaceholder)
                .accessibilityIdentifier("MobileTaskComposerPrompt")
                .taskComposerEditingCompletion(
                    isFocused: isPromptFocused,
                    endEditing: endEditing
                )
        }
    }

    private var accessoryBar: some View {
        VStack(spacing: 10) {
            if failureText != nil || completedOperationRecovery != nil {
                TaskComposerFailureRecoveryContent(
                    isSubmitting: isSubmitting,
                    failureTitle: failureTitle,
                    failureText: failureText,
                    completedOperationRecovery: completedOperationRecovery,
                    refreshCompletedOperation: refreshCompletedOperation,
                    requestStartAgain: requestStartAgain
                )
                .padding(.horizontal, 16)
            }

            HStack(spacing: 10) {
                optionsButton

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        agentPill

                        if !models.isEmpty, showsStandaloneModelPill {
                            modelPill
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity)

                submitButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        // Blend into the canvas like the reference composer; the keyboard
        // provides the visual boundary below.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background(Color(uiColor: .systemBackground))
    }

    private var optionsButton: some View {
        Button {
            isOptionsPresented = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(Color.primary.opacity(0.07), in: Circle())
                // Keep the compact 38pt visual while honoring the composer's
                // 44pt activation-target contract.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.options.title",
            defaultValue: "Task Options"
        ))
        .accessibilityIdentifier("MobileTaskComposerOptionsButton")
    }

    private var agentPill: some View {
        Menu {
            TaskComposerAgentMenuContent(
                value: agentMenuValue,
                actions: agentMenuActions
            )
        } label: {
            HStack(spacing: 7) {
                if let selectedTemplate {
                    TaskTemplateIcon(value: selectedTemplate.icon, size: 16)
                        .frame(width: 18, height: 18)

                    Text(agentPillTitle(for: selectedTemplate))
                        .lineLimit(1)
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)

                    Text(L10n.string(
                        "mobile.taskComposer.agent",
                        defaultValue: "Agent"
                    ))
                }

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.string("mobile.taskComposer.agent", defaultValue: "Agent"))
        .accessibilityValue(selectedTemplate?.name ?? "")
        .accessibilityHint(TaskComposerSheet.templateAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerAgentPill")
    }

    private var modelPill: some View {
        Menu {
            TaskComposerModelMenuContent(
                models: models,
                selectedModelID: selectedModelID,
                selectModel: selectModel
            )
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "cpu")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)

                Text(selectedModelName)
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .tint(Color.primary)
        .disabled(isDisabled)
        .taskComposerModelAccessibility(valueName: selectedModelName)
        .accessibilityIdentifier("MobileTaskComposerModelPill")
    }

    private var submitButton: some View {
        Button(action: submit) {
            Group {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isSubmitEnabled ? .white : .secondary)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .foregroundStyle(isSubmitEnabled ? Color.white : Color.secondary)
            .background(
                isSubmitEnabled ? Color.accentColor : Color.primary.opacity(0.12),
                in: Circle()
            )
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting || !isSubmitEnabled)
        .accessibilityLabel(L10n.string(
            "mobile.taskComposer.submit",
            defaultValue: "Start Task"
        ))
        .accessibilityHint(TaskComposerSheet.createAccessibilityHint)
        .accessibilityIdentifier("MobileTaskComposerSubmitButton")
    }

    private var selectedTemplate: MobileTaskTemplate? {
        selectedTemplateID.flatMap { id in templates.first { $0.id == id } }
    }

    /// Mirrors the classic agent menu's "name · model" title so the combined
    /// variant keeps a visible model indication even though its standalone
    /// pill is hidden in this layout.
    private func agentPillTitle(for template: MobileTaskTemplate) -> String {
        guard modelPickerVariant.renderedVariant == .combined,
              let modelName = models.first(where: { $0.id == selectedModelID })?.displayName
        else {
            return template.name
        }
        return "\(template.name) · \(modelName)"
    }

    /// Each lab variant keeps exactly one model entry point in this layout:
    /// combined lives inside the agent pill's submenus, contextRow lives in
    /// the Task Options context card, and the remaining variants collapse to
    /// the standalone bottom-bar pill.
    private var showsStandaloneModelPill: Bool {
        switch modelPickerVariant.renderedVariant {
        case .off, .combined, .contextRow:
            false
        case .separateRow, .trailingChip, .pillStrip:
            true
        }
    }

    private var selectedModelName: String {
        models.displayName(forSelected: selectedModelID)
    }

    private var navigationTitle: String {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return L10n.string("mobile.taskComposer.title", defaultValue: "New Task")
        }
        return TaskComposerDirectoryDisplayPath(path: directory).name
    }

    private var promptPlaceholder: String {
        guard !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return genericPromptPlaceholder
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.composer.promptPlaceholderFormat",
                defaultValue: "Describe a coding task in %@"
            ),
            TaskComposerDirectoryDisplayPath(path: directory).name
        )
    }

    private var agentMenuValue: TaskComposerAgentMenuValue {
        TaskComposerAgentMenuValue(
            templates: templates,
            selectedTemplateID: selectedTemplateID,
            modelPickerVariant: modelPickerVariant,
            selectedModelID: selectedModelID,
            isDisabled: isDisabled
        )
    }

    private var agentMenuActions: TaskComposerAgentMenuActions {
        TaskComposerAgentMenuActions(
            selectTemplate: selectTemplate,
            selectTemplateAndModel: selectTemplateAndModel,
            editTemplates: editTemplates
        )
    }
}
#endif
